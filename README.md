# SlashDeploy [![Build Status](https://travis-ci.org/remind101/slashdeploy.svg?branch=master)](https://travis-ci.org/remind101/slashdeploy) [![Code Climate](https://codeclimate.com/github/remind101/slashdeploy/badges/gpa.svg)](https://codeclimate.com/github/remind101/slashdeploy)

[SlashDeploy](https://slashdeploy.io) is a web app for triggering [GitHub Deployments](https://developer.github.com/v3/repos/deployments/) via a `/deploy` command in Slack.

## Installation

SlashDeploy is already hosted at https://slashdeploy.io. All you have to do is add it to your Slack team:

<a href="https://slashdeploy.io/slack/install"><img alt="Add to Slack" height="40" width="139" src="https://platform.slack-edge.com/img/add_to_slack@2x.png"></a>

## Usage

Deploy a repository to the default environment (production):

```console
/deploy ejholmes/acme-inc
```

Deploy a repository to a specific environment:

```console
/deploy ejholmes/acme-inc to staging
```

Deploy a branch:

```console
/deploy ejholmes/acme-inc@topic-branch to staging
```

And more at <https://slashdeploy.io/docs>.

## Features

* Create GitHub Deployments directly from Slack.
* Receive Slack DM's whenever GitHub Deployments change status.
* Trigger GitHub Deployments when a set of commit statuses pass (Continuous Delivery).
* Environment locking.

## Contributing

Contributions are highly welcome! If you'd like to contribute, please read [CONTRIBUTING.md](./CONTRIBUTING.md)
