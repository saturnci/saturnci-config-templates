# Environment for the rails_template job, which generates a fresh Rails app,
# applies the SaturnCI config template to it, pushes it, and waits for the
# resulting run.
#
# Unlike the other environments, this one does not install the SaturnCI repo's
# own Gemfile. The job generates a brand-new Rails app and bundles inside it, so
# the image only needs Ruby, Rails, Postgres client/server, git, and the SDK.
ARG RUBY_VERSION=4.0.7
FROM ruby:${RUBY_VERSION}-slim AS builder

RUN apt-get update && apt-get install -y \
  git \
  && rm -rf /var/lib/apt/lists/*

ARG SDK_COMMIT=1bd886b
RUN git clone https://github.com/saturnci/saturnci-sdk.git /tmp/saturnci-sdk \
  && cd /tmp/saturnci-sdk \
  && git checkout $SDK_COMMIT \
  && gem build saturnci-sdk.gemspec

FROM ruby:${RUBY_VERSION}-slim

COPY --from=builder /tmp/saturnci-sdk/saturnci-sdk-*.gem /tmp/
RUN gem install /tmp/saturnci-sdk-*.gem && rm /tmp/saturnci-sdk-*.gem

RUN apt-get update && apt-get install -y \
  build-essential \
  libpq-dev \
  libyaml-dev \
  nodejs \
  git \
  curl \
  # `rails new --database=postgresql` runs db:migrate, which needs a server to
  # talk to. The job starts this one itself so the environment stays a single
  # container.
  postgresql \
  postgresql-client \
  && rm -rf /var/lib/apt/lists/*

RUN gem install rails -v 8.1.4

WORKDIR /app

ENTRYPOINT ["ruby"]
