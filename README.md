# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Run tests (no local installs)

From the repository root (`rails_8/`):

```bash
# Rails / RSpec
docker compose run --rm benchmark_ui bundle exec rspec

# Go worker unit tests
docker compose run --rm golang_worker_test

# Node worker unit tests
docker compose run --rm node_worker node --test

# Python worker unit tests
docker compose run --rm python_worker python -m unittest discover -s tests -p 'test_*.py'
```
