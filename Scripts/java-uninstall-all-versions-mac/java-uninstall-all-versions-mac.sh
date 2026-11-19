#!/bin/bash
#
# Datto RMM Component - Java - Uninstall All Versions [Mac]
#
# Removes Java installed for the whole Mac, from any vendor, and nothing an
# application ships inside itself.
#
# Removed (Remove mode):
#   - Every JDK/JRE bundle in /Library/Java/JavaVirtualMachines that is a real
#     folder: Oracle, Eclipse Temurin / AdoptOpenJDK, Amazon Corretto, Azul Zulu,
#     Microsoft, BellSoft Liberica, IBM Semeru, SapMachine, and any other vendor.
#   - Oracle's Java 8 browser plug-in (/Library/Internet Plug-Ins/JavaAppletPlugin.plugin).
#   - Oracle's leftovers, only when nothing Java is kept: the Java Control Panel,
#     the Java updater and its launchd jobs, /Library/Application Support/Oracle/Java.
#   - Package receipts whose every file was inside a Java bundle that is now gone.
#
# Never touched:
#   - Java bundled inside an application (/Applications/Some.app/Contents/...).
#     This script never looks inside /Applications at all.
#   - Anything in /System or /usr: Apple's Java stubs (Java Web Start, Jar Launcher,
#     /usr/bin/java) are part of macOS.
#   - A symlink in /Library/Java/JavaVirtualMachines (Homebrew and similar tools
#     link their own JDK there); the link and its target are left alone.
#   - JDKs in users' home folders (~/Library/Java, IDE downloads, SDKMAN) and
#     Homebrew (/opt/homebrew, /usr/local). Report mode lists the per-user ones.
#
# It never stops a running program. Something already running on a removed
# Java keeps running until it quits; those processes are listed.
#
# usrMode      Remove (default) or Report. Report changes nothing but the UDF.
# usrKeep      Optional, comma-separated, matched case-insensitively against each
#              bundle's folder name, product name, vendor and version. Matches stay.
# usrUdfNumber Optional, 1-300: write a one-line summary to that UDF.
#
# Exit: 0 STATUS=CLEAN / FOUND (Report) / REMOVED, 1 STATUS=REFUSED,
#       3 STATUS=REMOVE_INCOMPLETE, 5 STATUS=ERROR.
#
# Runs as root. Bash 3.2 (every macOS since 10.14). No network, no Python.
# Source: https://github.com/TechCollective/DattoRMM_Components

SCRIPT_NAME='Java - Uninstall All Versions [Mac]'
JVM_DIR='/Library/Java/JavaVirtualMachines'
PLUGIN='/Library/Internet Plug-Ins/JavaAppletPlugin.plugin'
PREFPANE='/Library/PreferencePanes/JavaControlPanel.prefPane'
ORACLE_SUPPORT='/Library/Application Support/Oracle/Java'
ORACLE_HELPER='/Library/PrivilegedHelperTools/com.oracle.java.JavaUpdateHelper'
UDF_FILE='/var/root/.mono/registry/LocalMachine/software/centrastage/values.xml'
OWN_UDF_PREFIX='Java: '
PLISTBUDDY='/usr/libexec/PlistBuddy'
RECEIPT_RE='^(com\.oracle\.(jdk|jre)|net\.temurin\.|net\.adoptopenjdk\.|com\.amazon\.corretto|com\.azulsystems\.zulu|com\.microsoft\..*jdk|com\.bellsoft\.liberica|com\.ibm\.semeru|com\.sap\.sapmachine)'

shopt -s nullglob

say()    { printf '%s\n' "$*"; }
finish() { say "DETAIL=$2"; say "STATUS=$1"; exit "$3"; }
lower()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim()   { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
pval()   { "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null; }

say "$SCRIPT_NAME"
[ "$(id -u)" -eq 0 ] || finish ERROR 'Must run as root; Datto runs components as root.' 5
[ -x "$PLISTBUDDY" ] || finish ERROR "$PLISTBUDDY is missing; check this Mac by hand." 5

# ----------------------------------------------------------------- inputs ----

MODE=$(trim "${usrMode:-}")
case "$(lower "$MODE")" in
    ''|remove) MODE=Remove ;;
    report)    MODE=Report ;;
    *)         finish REFUSED 'usrMode must be Remove or Report.' 1 ;;
esac

KEEP_TERMS=()
IFS=',;' read -r -a raw_terms <<< "${usrKeep:-}"
for t in "${raw_terms[@]}"; do
    t=$(trim "$t")
    [ -z "$t" ] && continue
    [ ${#t} -lt 3 ] && finish REFUSED "usrKeep term '$t' is shorter than 3 characters; that would match almost anything. Use more of the name." 1
    KEEP_TERMS+=("$(lower "$t")")
done

UDF_NUM=0
UDF_RAW=$(trim "${usrUdfNumber:-}")
if [ -n "$UDF_RAW" ]; then
    case "$UDF_RAW" in *[!0-9]*) finish REFUSED 'usrUdfNumber must be blank (no UDF) or a number from 1 to 300.' 1 ;; esac
    [ ${#UDF_RAW} -le 3 ] && [ "$UDF_RAW" -ge 1 ] && [ "$UDF_RAW" -le 300 ] ||
        finish REFUSED 'usrUdfNumber must be blank (no UDF) or a number from 1 to 300.' 1
    UDF_NUM=$((10#$UDF_RAW))
fi

keep_list='none'
[ ${#KEEP_TERMS[@]} -gt 0 ] && keep_list=$(IFS=,; printf '%s' "${KEEP_TERMS[*]}")
say "Mode: $MODE | Keep terms: $keep_list | UDF: $([ "$UDF_NUM" -gt 0 ] && echo "Custom$UDF_NUM" || echo none) | macOS $(sw_vers -productVersion 2>/dev/null)"

is_kept() {
    local hay t
    [ ${#KEEP_TERMS[@]} -eq 0 ] && return 1
    hay=$(lower "$1")
    for t in "${KEEP_TERMS[@]}"; do
        case "$hay" in *"$t"*) return 0 ;; esac
    done
    return 1
}

# ------------------------------------------------------------------- UDF -----
# Edits the agent's values.xml with Apple's XML parser (JavaScript for
# Automation), so the file stays valid XML. Never overwrites another
# component's value.

udf_write() {
    [ "$UDF_NUM" -gt 0 ] || return 0
    local val="$1"
    [ ${#val} -gt 255 ] && val="${val:0:252}..."
    # The folder is made here, not in the JavaScript: there a JS null passed
    # as an options dictionary reaches Foundation as NSNull and crashes it.
    mkdir -p "${UDF_FILE%/*}" || { say "UDF=WRITE_FAILED Custom$UDF_NUM: could not create ${UDF_FILE%/*}"; return 0; }
    UDF_PATH="$UDF_FILE" UDF_NAME="Custom$UDF_NUM" UDF_VALUE="$val" UDF_OWN="$OWN_UDF_PREFIX" \
        /usr/bin/osascript -l JavaScript 2>&1 <<'JXA'
ObjC.import('Foundation');
var env = $.NSProcessInfo.processInfo.environment;
function E(k) { var v = env.objectForKey(k); return (v && !v.isNil()) ? v.js : ''; }
var path = E('UDF_PATH'), name = E('UDF_NAME'), value = E('UDF_VALUE'), own = E('UDF_OWN');
var result = '';
try {
    var fm = $.NSFileManager.defaultManager, doc = null;
    if (fm.fileExistsAtPath(path)) {
        doc = $.NSXMLDocument.alloc.initWithContentsOfURLOptionsError($.NSURL.fileURLWithPath(path), 0, Ref());
        if (!doc || doc.isNil() || doc.rootElement.isNil()) { throw new Error('could not parse ' + path); }
    } else {
        doc = $.NSXMLDocument.alloc.initWithRootElement($.NSXMLElement.elementWithName('values'));
    }
    // Walk the children by index: elementsForName hands back null, not an
    // empty list, when the file has no entries yet.
    var root = doc.rootElement, found = null, n = Number(root.childCount);
    for (var i = 0; i < n; i++) {
        var k = root.childAtIndex(i);
        if (Number(k.kind) !== 2 || k.name.js !== 'value') { continue; }   // 2 = NSXMLElementKind
        var a = k.attributeForName('name');
        if (a && !a.isNil() && a.stringValue.js === name) { found = k; break; }
    }
    if (found) {
        var cur = found.stringValue.js || '';
        if (cur && cur.indexOf(own) !== 0) {
            result = 'UDF=NOT_WRITTEN ' + name + ' already holds a value this component did not write (' + cur.length + ' characters).';
        } else {
            found.setStringValue(value);
        }
    } else {
        var el = $.NSXMLElement.elementWithNameStringValue('value', value);
        el.addAttribute($.NSXMLNode.attributeWithNameStringValue('name', name));
        el.addAttribute($.NSXMLNode.attributeWithNameStringValue('type', 'string'));
        root.addChild(el);
    }
    if (!result) {
        if (!doc.XMLDataWithOptions(1 << 17).writeToFileAtomically(path, true)) { throw new Error('could not write ' + path); }
        result = 'UDF=WRITTEN ' + name + ': ' + value;
    }
} catch (e) {
    result = 'UDF=WRITE_FAILED ' + name + ': ' + e.message;
}
result;
JXA
}

# ------------------------------------------------------------------ scan -----

R_PATHS=(); R_DESCS=(); K_DESCS=(); K_COUNT=0

scan() {
    R_PATHS=(); R_DESCS=(); K_DESCS=(); K_COUNT=0
    SYMLINKS=(); PLUGIN_STATE='absent'; PLUGIN_LABEL=''
    local b name info label vendor ver desc
    for b in "$JVM_DIR"/*.jdk "$JVM_DIR"/*.jre; do
        name=${b##*/}
        if [ -L "$b" ]; then
            SYMLINKS+=("$name -> $(readlink "$b")")
            continue
        fi
        [ -d "$b" ] || continue
        info="$b/Contents/Info.plist"
        label=$(pval "$info" CFBundleName); [ -z "$label" ] && label="$name"
        vendor=$(pval "$info" JavaVM:JVMVendor)
        ver=$(pval "$info" JavaVM:JVMVersion)
        desc="$label | ${ver:-version unknown} | ${vendor:-vendor unknown} | $b"
        if is_kept "$name $label $vendor $ver"; then
            K_DESCS+=("$desc"); K_COUNT=$((K_COUNT + 1))
        else
            R_PATHS+=("$b"); R_DESCS+=("$desc")
        fi
    done
    if [ -d "$PLUGIN" ] && [ ! -L "$PLUGIN" ]; then
        PLUGIN_LABEL="Oracle Java Plug-in $(pval "$PLUGIN/Contents/Info.plist" CFBundleVersion)"
        if is_kept "$PLUGIN_LABEL"; then PLUGIN_STATE='keep'; K_COUNT=$((K_COUNT + 1)); else PLUGIN_STATE='remove'; fi
    fi
}

oracle_leftovers() {
    local p
    for p in "$PREFPANE" "$ORACLE_SUPPORT" "$ORACLE_HELPER" \
             /Library/LaunchAgents/com.oracle.java.*.plist /Library/LaunchDaemons/com.oracle.java.*.plist; do
        [ -e "$p" ] || [ -L "$p" ] && printf '%s\n' "$p"
    done
}

# Receipts that describe only Java bundles which no longer exist.
orphan_receipts() {
    local id loc roots r gone
    for id in $(pkgutil --pkgs 2>/dev/null | grep -E "$RECEIPT_RE"); do
        loc=$(pkgutil --pkg-info "$id" 2>/dev/null | awk -F': ' '/^location:/{print $2}')
        roots=$(pkgutil --only-files --files "$id" 2>/dev/null | awk -v loc="$loc" -v jvm="$JVM_DIR" -v plug="$PLUGIN" '
            { p = "/" loc "/" $0; gsub(/\/+/, "/", p); n++
              if (index(p, jvm "/") == 1) { rest = substr(p, length(jvm) + 2); sub(/\/.*/, "", rest); r[jvm "/" rest] = 1 }
              else if (index(p, plug "/") == 1) { r[plug] = 1 }
              else { bad = 1; exit } }
            END { if (bad || n == 0) exit 1; for (k in r) print k }') || continue
        gone=1
        while IFS= read -r r; do
            [ -n "$r" ] && { [ -e "$r" ] || [ -L "$r" ]; } && gone=0
        done <<< "$roots"
        [ "$gone" -eq 1 ] && printf '%s\n' "$id"
    done
}

scan
STAMP=$(date '+%Y-%m-%d %H:%M')

say "System Java: $(( ${#R_PATHS[@]} + K_COUNT + $([ "$PLUGIN_STATE" = remove ] && echo 1 || echo 0) )) (remove $(( ${#R_PATHS[@]} + $([ "$PLUGIN_STATE" = remove ] && echo 1 || echo 0) )), keep $K_COUNT)"
for d in ${R_DESCS[@]+"${R_DESCS[@]}"}; do say "  [remove] $d"; done
for d in ${K_DESCS[@]+"${K_DESCS[@]}"}; do say "  [keep]   $d"; done
[ "$PLUGIN_STATE" = remove ] && say "  [remove] $PLUGIN_LABEL | $PLUGIN"
[ "$PLUGIN_STATE" = keep ]   && say "  [keep]   $PLUGIN_LABEL | $PLUGIN"
for s in ${SYMLINKS[@]+"${SYMLINKS[@]}"}; do say "  [leave]  symlink, managed elsewhere: $s"; done

USER_JDKS=(/Users/*/Library/Java/JavaVirtualMachines/*)
say "Per-user JDKs (left alone): ${#USER_JDKS[@]}"
for u in ${USER_JDKS[@]+"${USER_JDKS[@]}"}; do say "  [leave]  $u"; done

LEFTOVERS=$(oracle_leftovers)
RECEIPTS=$(orphan_receipts)
n_left=$(printf '%s' "$LEFTOVERS" | grep -c . )
n_rcpt=$(printf '%s' "$RECEIPTS" | grep -c . )
say "Oracle leftovers: $n_left | Orphaned Java package receipts: $n_rcpt"

n_remove=$(( ${#R_PATHS[@]} + $([ "$PLUGIN_STATE" = remove ] && echo 1 || echo 0) ))

# ---------------------------------------------------------------- report -----

if [ "$MODE" = Report ]; then
    if [ "$n_remove" -gt 0 ]; then
        names=$(for p in ${R_PATHS[@]+"${R_PATHS[@]}"}; do printf '%s; ' "${p##*/}"; done)
        [ "$PLUGIN_STATE" = remove ] && names="${names}${PLUGIN_LABEL}; "
        udf_write "Java: FOUND $n_remove | ${names%; } | $STAMP"
        finish FOUND "Report only, nothing changed. Remove would remove $n_remove item(s) and $n_left leftover(s), keep $K_COUNT." 0
    fi
    udf_write "Java: NONE | Kept $K_COUNT | $STAMP"
    finish CLEAN "Report only, nothing changed. No removable Java; $n_left leftover(s), $K_COUNT kept." 0
fi

if [ "$n_remove" -eq 0 ] && [ "$n_left" -eq 0 ] && [ "$n_rcpt" -eq 0 ]; then
    udf_write "Java: NONE | Kept $K_COUNT | $STAMP"
    finish CLEAN "No removable Java found; nothing changed. Kept: $K_COUNT." 0
fi

# ---------------------------------------------------------------- remove -----

remove_path() {
    # Deletes one path, only from the places this script owns.
    local p="$1"
    case "$p" in
        "$JVM_DIR"/*.jdk|"$JVM_DIR"/*.jre)
            [ "${p%/*}" = "$JVM_DIR" ] || { say "  [skip] not directly in $JVM_DIR: $p"; return 1; }
            [ -L "$p" ] && { say "  [skip] symlink left alone: $p"; return 1; } ;;
        "$PLUGIN"|"$PREFPANE"|"$ORACLE_SUPPORT"|"$ORACLE_HELPER"|/Library/LaunchAgents/com.oracle.java.*.plist|/Library/LaunchDaemons/com.oracle.java.*.plist) ;;
        *) say "  [skip] not a path this component removes: $p"; return 1 ;;
    esac
    rm -rf -- "$p"
    if [ -e "$p" ] || [ -L "$p" ]; then say "  [fail] could not delete $p"; return 1; fi
    say "  [ok] deleted $p"
}

# Programs running from what is about to go: listed, never stopped.
targets=(${R_PATHS[@]+"${R_PATHS[@]}"})
[ "$PLUGIN_STATE" = remove ] && targets+=("$PLUGIN")
# A function, not a case inside $( ): bash 3.2 misreads that and aborts.
list_running() {
    local pid cmd t
    ps -axo pid=,comm= 2>/dev/null | while read -r pid cmd; do
        for t in "$@"; do
            [ "${cmd#"$t"/}" != "$cmd" ] && printf '  %s (PID %s) keeps running until it quits\n' "${cmd##*/}" "$pid"
        done
    done
}
running=$(list_running ${targets[@]+"${targets[@]}"})
[ -n "$running" ] && { say 'Running from Java being removed:'; say "$running"; }

say 'Removing:'
for p in ${R_PATHS[@]+"${R_PATHS[@]}"}; do remove_path "$p"; done
[ "$PLUGIN_STATE" = remove ] && remove_path "$PLUGIN"

if [ "$K_COUNT" -eq 0 ] && [ "$PLUGIN_STATE" != keep ]; then
    say 'Oracle leftovers:'
    console_uid=$(stat -f %u /dev/console 2>/dev/null)
    for plist in /Library/LaunchDaemons/com.oracle.java.*.plist; do
        label=$(pval "$plist" Label)
        [ -n "$label" ] && launchctl bootout "system/$label" >/dev/null 2>&1
        remove_path "$plist"
    done
    for plist in /Library/LaunchAgents/com.oracle.java.*.plist; do
        label=$(pval "$plist" Label)
        [ -n "$label" ] && [ -n "$console_uid" ] && [ "$console_uid" -ne 0 ] &&
            launchctl bootout "gui/$console_uid/$label" >/dev/null 2>&1
        remove_path "$plist"
    done
    for p in "$PREFPANE" "$ORACLE_SUPPORT" "$ORACLE_HELPER"; do
        { [ -e "$p" ] || [ -L "$p" ]; } && remove_path "$p"
    done
    rmdir '/Library/Application Support/Oracle' 2>/dev/null && say '  [ok] removed empty /Library/Application Support/Oracle'
else
    say "Oracle leftovers left in place: $K_COUNT Java item(s) kept."
fi

say 'Package receipts:'
for id in $(orphan_receipts); do
    if pkgutil --forget "$id" >/dev/null 2>&1; then say "  [ok] forgot $id"; else say "  [fail] could not forget $id"; fi
done

# --------------------------------------------------------------- re-check ----

removed_count=$n_remove
scan
left=$(( ${#R_PATHS[@]} + $([ "$PLUGIN_STATE" = remove ] && echo 1 || echo 0) ))
removed_count=$((removed_count - left))

if [ "$left" -eq 0 ]; then
    udf_write "Java: REMOVED $removed_count | Kept $K_COUNT | $STAMP"
    finish REMOVED "Removed $removed_count item(s), kept $K_COUNT. Re-check found nothing left to remove." 0
fi

say 'Still present:'
for d in ${R_DESCS[@]+"${R_DESCS[@]}"}; do say "  [left] $d"; done
[ "$PLUGIN_STATE" = remove ] && say "  [left] $PLUGIN_LABEL | $PLUGIN"
names=$(for p in ${R_PATHS[@]+"${R_PATHS[@]}"}; do printf '%s; ' "${p##*/}"; done)
[ "$PLUGIN_STATE" = remove ] && names="${names}${PLUGIN_LABEL}; "
udf_write "Java: INCOMPLETE $left left | ${names%; } | $STAMP"
finish REMOVE_INCOMPLETE "$left item(s) still present; see the lines above." 3
