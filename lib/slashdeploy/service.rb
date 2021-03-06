module SlashDeploy
  # SlashDeploy::Service provides the core internal API for controllers to
  # consume. This composes the various backends and provides a very simple API
  # for performing actions.
  class Service
    # Client for interacting with GitHub.
    attr_accessor :github

    # Client for interacting with Slack.
    attr_accessor :slack

    def authorize!(user, repository)
      fail RepoUnauthorized, repository unless github.access?(user, repository.to_s)
    end

    # Sends a direct message to all of the users slack accounts.
    def direct_message(account, klass, attributes = {})
      return unless account
      message = klass.build attributes.merge(account: account)
      slack.direct_message(account, message)
    end

    # Pulls the latest .slashdeploy.yml file from the default branch.
    def update_repository_config(repository)
      raw_config = github.contents(repository, SlashDeploy::CONFIG_FILE_NAME)
      repository.configure!(raw_config)
    end

    # Creates a new AutoDeployment for the given sha.
    #
    # environment - Environment to deploy to.
    # sha         - Git sha to deploy.
    # user        - The User to attribute the deployment to.
    #
    # Returns an AutoDeployment.
    def create_auto_deployment(environment, sha, user)
      auto_deployment = environment.auto_deployments.create user: user, sha: sha
      return auto_deployment unless auto_deployment.valid?
      state = auto_deployment.state
      case state
      when AutoDeployment::STATE_READY
        auto_deploy auto_deployment
      when AutoDeployment::STATE_PENDING
        direct_message \
          auto_deployment.slack_account, \
          AutoDeploymentCreatedMessage, \
          auto_deployment: auto_deployment
        # schedule an AutoDeployment Watchdog to check up on this AutoDeployment.
        AutoDeploymentWatchdogWorker.schedule(auto_deployment.id)
      else
        fail "Unhandled #{state} state"
      end
      auto_deployment
    end

    # Used to track when a commit status context changes state. This will track
    # the new commit status, then deploy any auto deployments that are ready.
    # If the new status is failing, the user will receive a DM letting them
    # know.
    #
    # status - a Status object representing the new state.
    #
    # Returns nothing.
    def track_context_state_change(status)
      AutoDeployment.lock.active.where(sha: status.sha).each do |auto_deployment|
        state = auto_deployment.state
        case state
        when AutoDeployment::STATE_READY
          auto_deploy auto_deployment
        when AutoDeployment::STATE_FAILED
          direct_message \
            auto_deployment.slack_account, \
            AutoDeploymentFailedMessage, \
            auto_deployment: auto_deployment
        when AutoDeployment::STATE_PENDING
          nil
        else
          fail "Unhandled #{state} state"
        end
      end
    end

    # Creates a new deployment request as the given user.
    #
    # user        - The User requesting the deployment.
    # environment - The Environment to be deployed to.
    # ref         - A String git ref. If none is provided, defaults to the
    #               default ref.
    # options     - A Hash of extra options.
    #               :skip_cd_check - bypass continuous deployment, release
    #                                specified commit to environment.
    #               :force         - "force" the deployment, ignoring commit
    #                                status contexts.
    #               :strong_lock   - If set to true, even the user that locked
    #                                it won't be able to deploy.
    #
    # Returns a DeploymentResponse.
    def create_deployment(user, environment, ref = nil, options = {})
      authorize! user, environment.repository.to_s

      req = deployment_request(environment, ref, force: options[:force])

      # Check if the environment we're deploying to is configured for auto deployments.
      fail EnvironmentAutoDeploys if environment.auto_deploy_enabled? && !options[:skip_cd_check]

      # Check if the environment we're deploying to is locked.
      lock = environment.active_lock
      if lock && lock.user != user
        fail EnvironmentLockedError, lock
      else
        last_deployment = github.last_deployment(user, req.repository, req.environment)
        deployment = github.create_deployment(user, req)
        # schedule Github Deployment Watchdog to check up on this Github Deployment.
        GithubDeploymentWatchdogWorker.schedule(user.id, deployment.repository, deployment.id)
        DeploymentResponse.new(deployment: deployment, last_deployment: last_deployment)
      end
    end

    # Returns the last deployment for a repository and environment.
    #
    # user        - The User requesting the last deployment information.
    # repo        - The repository to retrieve the last deployment from.
    # environment - The Environment to retrieve the last deployment from.
    #
    # Returns github.last_deployment.
    def last_deployment(user, repo, environment)
      authorize! user, repo.to_s

      last_deployment = github.last_deployment(user, repo.to_s, environment.to_s)
    end

    # Attempts to lock the environment on the repo.
    #
    # environment - An Environment to lock.
    # options     - A hash of options.
    #               :message - An optional message.
    #               :force   - Steal the lock if the environment is already locked.
    #
    # Returns a Lock.
    def lock_environment(user, environment, options = {})
      authorize! user, environment.repository

      lock = environment.active_lock

      if lock
        return if lock.user == user # Already locked, nothing to do.
        fail EnvironmentLockedError, lock unless options[:force]
        direct_message \
          lock.slack_account,
          LockStolenMessage,
          environment: environment,
          thief: environment.slack_account_for(user)
        lock.unlock!
      end

      stolen = lock
      lock = environment.lock! user, options[:message]

      # I'm not sure why, but sometimes lock can be nil?
      if lock
        # schedule an LockNag Watchdog to check up on this Lock.
        LockNagWorker.schedule(lock.id)
      end

      LockResponse.new \
        lock: lock,
        stolen: stolen
    end

    # Unlocks an environment.
    #
    # environment - An Environment to unlock
    #
    # Returns nothing
    def unlock_environment(user, environment)
      authorize! user, environment.repository

      lock = environment.active_lock
      return unless lock
      lock.unlock!
    end

    # Unlock all of a User's active locks.
    # Returns nothing
    def unlock_all(user)
      user.unlock_all!
    end

    # Creates a MessageAction, generating a uuid for the callback_id
    #
    #  action - The class that the message action will execute. Implements BaseAction.
    #  options - params hash that will be passed to the command
    #
    #  Returns a MessageAction
    def create_message_action(action, options = {})
      MessageAction.create!(
        callback_id: SecureRandom.uuid,
        action_params: options.to_json,
        action: action.name
      )
    end

    private

    # Triggers an auto deployment if the AutoDeployment is ready.
    #
    # auto_deployment - An AutoDeployment.
    #
    # Returns nothing.
    def auto_deploy(auto_deployment)
      fail "auto_deploy called on AutoDeployment that's not ready: #{auto_deployment.id}" unless auto_deployment.ready?

      begin
        environment = auto_deployment.environment

        # Check if the environment we're deploying to is locked.
        if environment.locked?
          direct_message \
            auto_deployment.slack_account, \
            AutoDeploymentLockedMessage, \
            auto_deployment: auto_deployment, \
            lock: environment.active_lock
          return
        end

        # An auto_deployment in the 'ready' state doesn't need context checks.
        # So when creating the GitHub Deployment we set force to true.
        github.create_deployment(
          auto_deployment.deployer,
          deployment_request(
            environment, auto_deployment.sha, force: true
          )
        )

      ensure
        auto_deployment.done!
      end
    end

    def deployment_request(environment, ref, options = {})
      DeploymentRequest.new(
        repository:  environment.repository.to_s,
        environment: environment.to_s,
        ref:         ref || environment.default_ref,
        force:       options[:force]
      )
    end
  end
end
