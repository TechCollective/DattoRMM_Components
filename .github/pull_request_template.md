## What this changes

<!-- The component name as saved in Datto, and what changed. If it is new, say
     what it does in one sentence. -->

## Why

<!-- What problem this solves. For an adopted component: where it came from,
     its author, and its licence. -->

## Tested

<!-- What was run, on what, and what the output was. "Not yet run" is a valid
     answer — say it rather than leaving this blank. -->

## Checklist

This repository is **public**:

- [ ] No customer or site names — script, README, commit messages, branch name
- [ ] No hostnames, IP addresses, subnets or AD domain names
- [ ] No keys, tokens, tenant ids, licence keys or account numbers
- [ ] No values tuned for one customer — those are input variables with neutral defaults
- [ ] No output captured from a real device

The component:

- [ ] Named to the standard, including `[Win]` `[Mac]` `[Lin]` tags
- [ ] Filed under the category it is saved under in Datto
- [ ] `README.md` present in this same PR, with input variables and their safe ranges
- [ ] Nothing secret reaches stdout
- [ ] It does not always exit 0
- [ ] A monitor emits exactly one result block on every path, including unexpected death
- [ ] Provenance and licence recorded, if adopted from outside
- [ ] A `.cpt` committed here, if any, matches the script in this PR
- [ ] A `.cpt` committed here, if any, carries no attachment (`unzip -l` shows only `command.bat`, `resource.xml`, `icon.png`) — an Applications export bundles the vendor installer
