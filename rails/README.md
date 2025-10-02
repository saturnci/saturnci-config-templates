# Rails Config Template

This Rails application template automatically adds SaturnCI configuration to your existing Rails application.

## Usage

From your Rails application directory, run:

```bash
rails app:template LOCATION=https://raw.githubusercontent.com/saturnci/saturnci-config-templates/main/rails/template.rb
```

## What it adds

The template will add the following to your Rails application:

### SaturnCI Configuration (`.saturnci/` directory)
- **`Dockerfile`** - Defines the test environment container with Ruby, PostgreSQL, and Node.js
- **`docker-compose.yml`** - Orchestrates test services (app, PostgreSQL, Chrome for system tests)
- **`database.yml`** - Test database configuration using environment variables
- **`up.sh`** - Convenience script to start the test environment
- **`down.sh`** - Convenience script to stop the test environment
- **`run.sh`** - Convenience script to run commands in the test environment
- **`.env`** - Basic environment variables (add your secrets here)
- **`.gitignore`** - Ignores the `.env` file

### Testing Setup
- **RSpec configuration** (if not already present)
- **`.rspec`** file with recommended settings

## Requirements

- Rails application
- PostgreSQL database (configured in `database.yml`)
- Git repository

## After applying the template

1. **Install gems**: Run `bundle install` to install any new gems (RSpec, etc.)

2. **Commit changes**:
   ```bash
   git add .
   git commit -m "Add SaturnCI configuration"
   git push
   ```

3. **Add to SaturnCI**: Add your repository at https://app.saturnci.com

4. **Push code**: Your next push will trigger a test run!

## Local testing

You can test your SaturnCI configuration locally:

```bash
cd .saturnci

# Start the test environment
./up.sh

# Run your tests
./run.sh bundle exec rspec

# Get a shell in the test environment
./run.sh bash

# Stop the test environment
./down.sh
```

## Environment Variables

Add any required environment variables to `.saturnci/.env`:

```bash
# Example:
API_KEY=your_api_key_here
DATABASE_URL=postgresql://user:password@localhost/test_db
```

**Note**: The `.env` file is gitignored for security. Set production secrets in your SaturnCI repository settings.

## Customization

### Database Configuration
The template assumes PostgreSQL. To use a different database:

1. Update `.saturnci/docker-compose.yml` services
2. Update `.saturnci/database.yml` configuration
3. Update `.saturnci/Dockerfile` to install appropriate database libraries

### Additional Services
To add services like Redis, Elasticsearch, etc.:

1. Add the service to `.saturnci/docker-compose.yml`
2. Update the `depends_on` section for `saturn_test_app`
3. Add any required environment variables to `.env`

## Troubleshooting

### Asset Precompilation Issues
If you see database connection errors during asset precompilation, the template includes dummy environment variables to prevent this issue.

### Permission Errors
Make sure the convenience scripts are executable:
```bash
chmod +x .saturnci/*.sh
```

### Database Connection Issues
Verify your database configuration in `.saturnci/database.yml` and ensure the PostgreSQL service is running in Docker Compose.