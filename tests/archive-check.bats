#!/usr/bin/env bats
# bin/keel-archive-check: the copy of the project archive inside a build tree
# has to be the archive as it is right now. Everything here runs against
# scratch directories; no root, no network, no fab.

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    CHECK="$ROOT/bin/keel-archive-check"
    scratch="$BATS_TEST_TMPDIR/archive"
    DIST=trixie-staging
    ARCH=amd64
    INDEX="dists/$DIST/main/binary-$ARCH/Packages"

    SOURCE="$scratch/srv/keel-apt/repo"
    TREE="$scratch/build/root.patched"
    mkdir -p "$SOURCE/$(dirname "$INDEX")" "$TREE/srv/keel-apt/repo/$(dirname "$INDEX")"

    write_index "$SOURCE/$INDEX" 2.3.6+keel4
    write_index "$TREE/srv/keel-apt/repo/$INDEX" 2.3.6+keel4
}

write_index() {
    cat > "$1" <<INDEX
Package: inithooks
Version: $2
Architecture: all
INDEX
}

@test "a copy that is the archive passes and says so" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" root.patched
    [ "$status" -eq 0 ]
    [[ "$output" == *"[archive-check root.patched]"* ]]
    [[ "$output" == *"is the archive at $SOURCE/$INDEX"* ]]
}

@test "the label defaults to the tree when it is not given" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[archive-check $TREE]"* ]]
}

@test "a copy of an older archive fails and shows what changed" {
    write_index "$TREE/srv/keel-apt/repo/$INDEX" 2.3.6+keel1
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not $SOURCE/$INDEX"* ]]
    [[ "$output" == *"-Version: 2.3.6+keel1"* ]]
    [[ "$output" == *"+Version: 2.3.6+keel4"* ]]
    [[ "$output" == *"build/stamps/bootstrap"* ]]
}

@test "a build tree with no copy at all fails" {
    rm -f "$TREE/srv/keel-apt/repo/$INDEX"
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"the build tree has no archive index"* ]]
}

@test "an archive with no index for this distribution fails" {
    run "$CHECK" "$SOURCE" "$TREE" trixie-nowhere "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"the archive has no index"* ]]
}

@test "too few arguments is a usage error" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
}

@test "too many arguments is a usage error" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" label extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
}

@test "an empty argument is a usage error rather than a wrong path" {
    run "$CHECK" "$SOURCE" "$TREE" "" "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
}
