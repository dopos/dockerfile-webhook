# dcape webhook Dockerfile

This Dockerfile used to build image with

* Official [docker](https://hub.docker.com/_/docker/) image as base
* [webhook](https://github.com/adnanh/webhook)
* hook support apps (curl, make, bash, git, apache2-utils, jq)
* [dcape](https://github.com/dopos/dcape) deploy hook script

Dockerfile uses two-stage build.

## Usage

See [sample at dcape CIS](https://github.com/dopos/dcape/tree/master/apps/cis)

## License

The MIT License (MIT), see [LICENSE](LICENSE).

Copyright (c) 2017 Alexey Kovrizhkin <lekovr+dopos@gmail.com>
