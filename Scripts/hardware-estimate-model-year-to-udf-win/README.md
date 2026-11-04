# Hardware - Estimate Model Year to UDF [Win]

Estimates the year a Windows machine's model came out and writes it to a Datto UDF, so machine age can be filtered and reported on across the fleet.

> **Status: Not Validated.** Written 2026-11-04. The rules were checked against every Dell, Lenovo and Apple model string and a representative set of CPU strings Datto had reported for our fleet; the script's estimate logic was run against simulated hardware. Not yet run on a real device.

## What it does

**Read-only apart from one UDF value.** It reads the manufacturer, model, product name and CPU from WMI and writes one line to `HKLM\SOFTWARE\CentraStage\Custom<n>`, which the Datto agent picks up as UDF *n* on its next check-in. No network calls, nothing installed, nothing else changed.

The value starts with the year, so it sorts and filters cleanly:

- `2021 | high | Latitude 5420`
- `2023 | high | ThinkPad T14 Gen 4`
- `2021 | medium | 20W0002MUS | by machine type`
- `2020-2021 | medium | XPS 13 9310 | by CPU`
- `Unknown | Contoso Widget 9000`
- `VM | virtual machine`

It is an estimate of when the **model** was current, not a ship date. A unit can ship up to about a year after its model launched, desktops especially. For a firm date, use the Dell or Lenovo warranty lookup.

How it estimates, best clue first:

- **Model name.** Dell Latitude and OptiPlex names encode the year (5420 is 2021, 7070 is 2019), as do Dell's 2025 product codes (PC14250: 25 = 2025). Lenovo product names carry a generation (T14 Gen 4) or, before 2020, a year digit (T480). OptiPlex 7010 and 7020 were each used twice, a decade apart; the CPU settles which.
- **Lenovo machine type.** Datto and WMI report Lenovo models as machine-type codes (21HD0086US). Lenovo assigns these roughly in sequence, so the first four characters give the year to within about a year. Used when the product name doesn't give a generation.
- **CPU.** Intel generation, Core Ultra series, Ryzen series, Snapdragon. Used for models whose names don't track the year (Precision, Vostro, Inspiron, XPS, HP, Surface).
- **Virtual machines** are written as `VM` and **unrecognised hardware** as `Unknown`, so both can be filtered out of age reports.

If the model and the CPU disagree by more than a year, the job output carries a `WARNING:` line.

The rules mirror the Machine Year Estimator page. **Change both together.**

It will not overwrite a UDF value that this component did not write (anything not starting with a year, `Unknown` or `VM`), unless `usrOverwriteForeign` is `Yes`. It never prints the existing value, only its length, since a UDF can hold anything, including a recovery key.

## Installing it in Datto

Automation → Components → New Component, or import the `.cpt` that CI attaches to the pull request.

| Field | Value |
|---|---|
| Name | `Hardware - Estimate Model Year to UDF [Win]` |
| Description | Writes an estimated build year from model and CPU to a UDF (default 10). Read-only otherwise; won't overwrite another component's value. |
| Category | **Scripts** |
| Script type | PowerShell |
| Target OS | Windows |
| Level | 1 (Basic). Anyone may run it; it only reads hardware and writes one UDF. |
| Timeout | 120 seconds |
| Attachments | None |

Paste the whole of `hardware-estimate-model-year-to-udf-win.ps1` as the script body, then add the input variables below.

Label the UDF in Setup → Account Settings → User-Defined Fields. We use **UDF 10, "Build Year (Estimate)"**.

## Input variables

| Name | Type | Default | Safe range / notes |
|---|---|---|---|
| `usrUdfNumber` | String | `10` | A whole number from 1 to 300. Anything else is refused with exit 1 and nothing is written. |
| `usrOverwriteForeign` | Selection: `No` / `Yes` | `No` | `No` leaves a UDF holding another component's value alone (exit 3). Set `Yes` only after confirming that value is not needed. |

No customer-specific value is hardcoded.

`TC_TEST_HARDWARE` is a test hook, not an input variable: when set, its `Manufacturer|Model|ProductVersion|CPU` text replaces WMI. Only this repo's Tier 1 test sets it. It cannot change anything but the text written.

## Exit behaviour

| Exit | Status | Meaning |
|---|---|---|
| 0 | `WRITTEN` | The estimate was written. |
| 0 | `UNCHANGED` | The UDF already held this exact value. |
| 0 | `NO_ESTIMATE` | No rule matched; `Unknown \| <make model>` was written so the device still shows up in reports. |
| 1 | `REFUSED` | An input variable is invalid. Nothing was written. |
| 2 | `WRITE_FAILED` | The registry write did not stick. |
| 3 | `FOREIGN_VALUE` | The UDF holds a value this component did not write. Nothing was changed. |

Every path ends with a `DETAIL=` line and a `STATUS=` line.

## How to tell it worked

A healthy run lists the hardware it read, one `Clue:` line per estimate it considered, a `Result:` line with the value written and `STATUS=WRITTEN`. The UDF shows the value in Datto after the agent's next check-in, not instantly.

## Test order

Never a customer first.

1. One internal device.
2. One site, one device in it, with the job scoped to that device.
3. Wider, only after the first two.

## Known limits

- Windows only. A Mac version is a separate component (shell script); Macs are simpler, since the model identifier gives the year almost directly.
- Lenovo machine-type estimates can be a year off; the product name, when WMI reports one, is better and is preferred.
- Celeron, Pentium, Xeon, EPYC, older AMD and unusual CPUs give no CPU estimate, so servers and budget machines often come out `Unknown`.
- Not run yet on Windows 10 or on a 32-bit PowerShell host. It writes through the same registry view as Datto's documented `REG ADD`, so it should land where the agent reads either way; the first internal run confirms it.

## Open questions

- Existing values in UDF 10 on some devices were confirmed as technician typos (2026-11-04). Clear them, or run the first fleet-wide pass with `usrOverwriteForeign` set to `Yes`; leave it at `No` for the initial-audit trigger so the guard stays on.
- Planned trigger: the initial audit for new devices, plus a one-off run across existing workstations.
