# SaturnCI Config Templates

This repository contains templates for automatically generating SaturnCI configuration in your projects.

## What are Config Templates?

Config templates are framework-specific scripts that automatically add SaturnCI configuration to your existing projects. They generate the necessary files and settings to integrate your project with SaturnCI's continuous integration platform.

## Available Templates

### Rails
- **Location**: [`rails/template.rb`](rails/template.rb)
- **Usage**: See [Rails README](rails/README.md)
- **Generates**: `.saturnci/` directory with Docker configuration, database setup, and RSpec integration

## Quick Start

### Rails Applications

From your Rails application directory, run:

```bash
rails app:template LOCATION=https://raw.githubusercontent.com/saturnci/saturnci-config-templates/main/rails/template.rb
```

This will:
1. Add `.saturnci/` directory with all necessary configuration files
2. Set up RSpec if not already present
3. Configure Docker environment for testing
4. Add convenience scripts for local testing

After running the template:
1. Commit the changes to your repository
2. Add your repository to SaturnCI at https://app.saturnci.com
3. Push your code to trigger your first test run!

## What Gets Generated

All templates generate a `.saturnci/` directory containing:

- **Dockerfile** - Defines the test environment container
- **docker-compose.yml** - Orchestrates test services (app, database, browser)
- **database.yml** - Test database configuration
- **Convenience scripts** - `up.sh`, `down.sh`, `run.sh` for local testing

## Local Testing

Test your SaturnCI configuration locally:

```bash
cd .saturnci
./up.sh                    # Start test environment
./run.sh bundle exec rspec # Run your tests
./down.sh                  # Stop test environment
```

## Contributing

To add support for a new framework:

1. Create a new directory named after the framework
2. Add a setup script that generates `.saturnci/` configuration
3. Include a README with usage instructions
4. Update this main README

## Support

- 📚 [SaturnCI Documentation](https://docs.saturnci.com)
- 🐛 [Report Issues](https://github.com/saturnci/saturnci-config-templates/issues)
- 💬 [Community Support](https://github.com/saturnci/saturnci-config-templates/discussions)