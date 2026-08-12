#!/usr/bin/env bash
# The classic: STAGING_DIR is unset, so the path expands to "/".
# Printed rather than run, for obvious reasons.
echo "rm -rf ${STAGING_DIR}/"
