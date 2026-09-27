#!/usr/bin/env bats
# conf.d/zz-project-packages: what the build installed has to be what the
# project archive offers, and no version is written down anywhere. The script
# runs for real against a scratch tree, with dpkg, dpkg-query and apt-cache as
# PATH stubs driven by fixture files. No root, no chroot, no apt.

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    SCRIPT="$ROOT/conf.d/zz-project-packages"
    scratch="$BATS_TEST_TMPDIR/packages"
    ARCH=amd64
    DIST=trixie-staging

    export KEEL_APT_ROOT="$scratch/srv/keel-apt"
    export KEEL_STAGING_LIST="$scratch/apt/sources.list.d/keel-staging.list"
    export KEEL_SOURCES="$scratch/apt/sources.list.d/keel.sources"
    export KEEL_APT_LISTS="$scratch/apt/lists"
    export FIXTURES="$scratch/fixtures"

    INDEX="$KEEL_APT_ROOT/repo/dists/$DIST/main/binary-$ARCH/Packages"
    mkdir -p "$(dirname "$INDEX")" "$(dirname "$KEEL_STAGING_LIST")" \
        "$KEEL_APT_LISTS" "$FIXTURES" "$scratch/bin"
    touch "$KEEL_APT_LISTS/keel_Packages"

    echo "deb [trusted=yes] file://$KEEL_APT_ROOT/repo $DIST main" > "$KEEL_STAGING_LIST"
    printf 'Types: deb\nURIs: https://apt.keellinux.org\nEnabled: no\n' > "$KEEL_SOURCES"

    offer inithooks 2.3.6+keel4
    offer confconsole 2.2.3+keel2
    offer keel 0.2.1
    for package in inithooks confconsole keel; do
        candidate "$package" "$(archive_version "$package")"
        from_project_archive "$package" "$(archive_version "$package")"
        installed "$package" "$(archive_version "$package")" "install ok installed"
    done

    stub dpkg '[ "$1" = --print-architecture ] && echo amd64'
    stub apt-cache 'cat "$FIXTURES/$1.$2" 2>/dev/null; exit 0'
    stub dpkg-query '
        case "$3" in
            *Version*) field=version ;;
            *) field=status ;;
        esac
        [ -f "$FIXTURES/installed.$4" ] || exit 1
        sed -n "s/^$field=//p" "$FIXTURES/installed.$4"
    '
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

# the package index of the archive: one stanza per offered version
offer() {
    printf 'Package: %s\nVersion: %s\nArchitecture: all\n\n' "$1" "$2" >> "$INDEX"
}

archive_version() {
    awk -v want="$1" '$1 == "Package:" { p = $2 } $1 == "Version:" && p == want { print $2 }' "$INDEX"
}

candidate() { printf '%s:\n  Installed: %s\n  Candidate: %s\n' "$1" "$2" "$2" > "$FIXTURES/policy.$1"; }

from_project_archive() {
    printf ' %s | %s | file:%s/repo %s/main amd64 Packages\n' \
        "$1" "$2" "$KEEL_APT_ROOT" "$DIST" > "$FIXTURES/madison.$1"
}

from_upstream() {
    printf ' %s | %s | http://archive.turnkeylinux.org/debian trixie/main amd64 Packages\n' \
        "$1" "$2" > "$FIXTURES/madison.$1"
}

installed() { printf 'version=%s\nstatus=%s\n' "$2" "$3" > "$FIXTURES/installed.$1"; }

@test "the three project packages at the versions the archive offers pass" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks 2.3.6+keel4, the candidate of the project archive"* ]]
    [[ "$output" == *"confconsole 2.2.3+keel2, the candidate of the project archive"* ]]
    [[ "$output" == *"keel 0.2.1, the candidate of the project archive"* ]]
}

@test "the build time package source is gone once the packages check out" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$KEEL_APT_ROOT" ]
    [ ! -e "$KEEL_STAGING_LIST" ]
    [ -z "$(ls -A "$KEEL_APT_LISTS")" ]
    [ -f "$KEEL_SOURCES" ]
}

@test "the recipe names no version: a new publication is simply the new candidate" {
    rm "$INDEX"
    offer inithooks 2.3.7+keel9
    offer confconsole 2.3.0+keel3
    offer keel 0.3.0
    for package in inithooks confconsole keel; do
        candidate "$package" "$(archive_version "$package")"
        from_project_archive "$package" "$(archive_version "$package")"
        installed "$package" "$(archive_version "$package")" "install ok installed"
    done
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks 2.3.7+keel9"* ]]
    [[ "$output" == *"keel 0.3.0"* ]]
}

@test "yesterday's package with today's archive fails" {
    installed inithooks 2.3.6+keel1 "install ok installed"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"inithooks 2.3.6+keel1 is installed and the project archive offers 2.3.6+keel4"* ]]
    [[ "$output" == *"stale index"* ]]
}

@test "an index that is not the archive the build read fails" {
    candidate inithooks 2.3.6+keel1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"apt would install '2.3.6+keel1' and the project archive offers '2.3.6+keel4'"* ]]
}

@test "an upstream build of the same version fails" {
    from_upstream confconsole 2.2.3+keel2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confconsole 2.2.3+keel2 does not come from"* ]]
    [[ "$output" == *"it is an upstream build"* ]]
}

@test "a package the archive does not offer fails" {
    rm "$INDEX"
    offer inithooks 2.3.6+keel4
    offer confconsole 2.2.3+keel2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel:"* ]]
    [[ "$output" == *"offers 0 versions (none), expected one"* ]]
}

@test "an archive that offers two versions of a package fails" {
    offer keel 0.2.2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"offers 2 versions (0.2.1 0.2.2), expected one"* ]]
}

@test "a package that is not installed fails" {
    rm "$FIXTURES/installed.keel"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel is not installed"* ]]
}

@test "a half configured package fails even at the right version" {
    installed confconsole 2.2.3+keel2 "install ok unpacked"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confconsole is 'install ok unpacked', not 'install ok installed'"* ]]
}

@test "a build with no project archive in its source list fails" {
    echo "# nothing here" > "$KEEL_STAGING_LIST"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no file: source in $KEEL_STAGING_LIST"* ]]
}

@test "a source list that names a distribution the archive has not got fails" {
    echo "deb [trusted=yes] file://$KEEL_APT_ROOT/repo trixie-nowhere main" > "$KEEL_STAGING_LIST"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no package index at"* ]]
    [[ "$output" == *"trixie-nowhere"* ]]
}

@test "the future signed repository has to stay in place, disabled" {
    printf 'Types: deb\nURIs: https://apt.keellinux.org\nEnabled: yes\n' > "$KEEL_SOURCES"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
}
