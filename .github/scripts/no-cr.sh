#!/bin/bash
# Fails when a file of the repository that ends up on Linux holds a carriage return: a script, a template or a guide.
# A shell script with "sync\r" stops with "command not found" on the VM. Usage, in the root of the repository:
# .github/scripts/no-cr.sh
set -u
bad=""
count=0
while IFS= read -r -d '' f; do
  count=$((count + 1))
  if [ "$(tr -cd '\015' < "$f" | wc -c)" -ne 0 ]; then bad="$bad $f"; fi
done < <(git ls-files -z -- '*.sh' '*.yaml' '*.yml' '*.bicep' '*.tf' '*.tfvars' '*.hcl' '*.json' '*.md')
if [ -n "$bad" ]; then
  echo "Carriage return in:$bad"
  exit 1
fi
echo "No carriage return in $count files"
