# Component Packaging Self-Test [Win]

A throwaway component whose only job is to prove that a `.cpt` built by
[`tools/cpt.py`](../cpt.py) imports into Datto RMM with everything intact. It is
tooling, not a real component, which is why it lives under `tools/` and not
under `Scripts/`.

**It makes no change to the endpoint.** It reads its own input variables back
out of the environment, compares them against the defaults declared in
`component.json`, and prints a pass/fail report.

## Build it

    python3 tools/cpt.py pack tools/test-component -o "Component Packaging Self-Test WIN.cpt"

## Run the test

1. In Datto RMM, go to **Components → New Component → Import Component** and
   upload the `.cpt`.
2. Confirm the Component Library shows:
   * Name `Component Packaging Self-Test [Win]`, category **Scripts**
   * A green tick icon, not a broken image
   * Four input variables, with `TestChoice` rendering as a **drop-down**
     offering *First choice* / *Second choice* / *Third choice*, defaulted to
     *Second choice*
   * `TestEmpty` present with a blank default
3. Run it against one test device, changing nothing.
4. Read the standard output.

## Reading the result

`PASS - component imported and all 4 input variables arrived as declared`, with
exit code 0, means the format is correct: the ZIP layout, `resource.xml`, and
all three variable kinds (`string`, `boolean`, `map`) survived the round trip.
The build pipeline can be trusted with real components.

A `FAIL` line names the variables that did not arrive as declared. If you edited
a value in the Datto UI before running, that is the expected cause. Otherwise
`component.json` and the packaged `resource.xml` disagree, and the packer is
wrong.

Anything that stops before the report — an import that is rejected, a component
that appears with no variables, a drop-down that shows `alpha`/`beta`/`gamma`
instead of the friendly names — is a packaging fault, and the section it points
at is documented in [`tools/README.md`](../README.md).

## After the test

Delete the component from Datto. It has served its purpose, and it should not
sit in the Component Library where someone can schedule it.

## What each variable is for

| Variable | Type | Proves |
|---|---|---|
| `TestString` | string | Ordinary text and a non-empty `<defaultVal>` |
| `TestEmpty` | string | A self-closed `<defaultVal/>` survives; arrives empty or unset |
| `TestBoolean` | boolean | Booleans reach the script as the literal text `true`/`false` |
| `TestChoice` | map | `selectionKeyValue` ordering; the script gets the **value**, the UI shows the **name** |
