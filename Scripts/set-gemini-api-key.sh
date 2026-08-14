#!/bin/zsh
set -euo pipefail

readonly service="com.orbitusrobotics.Cerebro.gemini"
readonly account="api-key"

print "Enter the Gemini API key at the secure Keychain prompt."
# With -w last and no value, macOS prompts without placing the secret in shell
# history, standard input pipelines, or the process argument list.
security add-generic-password -U -a "${account}" -s "${service}" -w
print "Gemini API key saved in the login Keychain. Restart Cerebro to use it."
