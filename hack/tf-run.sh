#!/bin/sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Wrapper for the terraform archetype's state-touching tasks: inject
# secrets/env via dotty when the working directory (the module being targeted)
# carries a .env.dotty, and run the command untouched otherwise — dotty env
# run fails hard when it has nothing to inject.
set -eu

if [ -f .env.dotty ]; then
  exec dotty env run -- "$@"
fi
exec "$@"
