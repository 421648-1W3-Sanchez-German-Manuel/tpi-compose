#!/bin/sh
# Loads a dotenv file (KEY=value per line, the format the Vault Agent renders)
# into the environment and runs a command. Values are taken literally: nothing
# is expanded, so a "$" or a space in a secret is safe.
#
#   load-env.sh /run/secrets/app.env java -jar app.jar
#   load-env.sh /run/secrets/app.env sh -c 'exec java $JAVA_OPTS -jar app.jar'
#
# Use the sh -c form when the command line itself needs a variable from the file
# (JAVA_OPTS): the single quotes make the inner shell expand it after loading.
set -eu

file="${1:?usage: load-env.sh <env-file> <command> [args...]}"
shift

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  export "${line%%=*}=${line#*=}"
done < "$file"

exec "$@"
