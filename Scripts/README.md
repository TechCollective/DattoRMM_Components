# Scripts

Datto RMM **script** components — components that do something and finish, as
opposed to monitors that report a condition.

Named `[Subject] - [Action]`, the action a verb phrase in the imperative:
`Windows Update - Reset Update Components [Win]`. An uninstall is a script, not
a deployment: `Adobe Acrobat Reader - Uninstall [Win]`.

If a script does three unrelated things the name will not come out cleanly —
that is the signal to split it.

One folder per component. See [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

Empty means nothing has been created or changed here since the rule took
effect — not that we have no script components.
