package slashdeploy

import (
	"github.com/jmoiron/sqlx"
	"golang.org/x/net/context"
)

// Client is a primary client to performing actions in SlashDeploy.
type Client struct {
	Users       *UsersService
	Deployments *DeploymentsService

	// BuildDeployer is a function that will be called to return a Deployer
	// instance that can be used to create the deployment as the given user.
	BuildDeployer func(*User) Deployer

	db *sqlx.DB
}

// New builds a new Client instance.
func New(db *sqlx.DB) *Client {
	c := &Client{db: db}
	c.Users = &UsersService{Client: c}
	c.Deployments = &DeploymentsService{Client: c}
	return c
}

func (c *Client) CreateDeployment(ctx context.Context, req DeploymentRequest) (*Deployment, error) {
	return c.Deployments.CreateDeployment(ctx, req)
}

func (c *Client) FindUser(id string) (*User, error) {
	return c.Users.FindUser(id)
}

func (c *Client) CreateUser(user *User) error {
	return c.Users.CreateUser(user)
}

// Close closes the db connection.
func (c *Client) Close() error {
	return c.db.Close()
}
