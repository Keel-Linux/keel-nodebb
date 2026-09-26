#!/usr/bin/python3
"""Ask for the NodeBB first boot values that the conf did not provide.

Called by firstboot.d/40nodebb only when a terminal is attached and a value
is absent; prints one KEY=value line per requested name on stdout so the
hook keeps the decisions and this file keeps the dialogs.

Syntax: nodebb.py NAME [NAME ...]      NAME is APP_PASS
"""

import sys

from libinithooks.dialog_wrapper import Dialog

TITLE = "Keel - First boot configuration"


def ask(name: str, dialog: Dialog) -> str:
    if name == "APP_PASS":
        return dialog.get_password(
            "NodeBB admin password",
            "Enter the password for the NodeBB 'admin' account.")
    raise SystemExit(f"nodebb.py: unknown value name {name!r}")


def main(names: list[str]) -> int:
    if not names:
        print(__doc__, file=sys.stderr)
        return 1
    dialog = Dialog(TITLE)
    for name in names:
        print(f"{name}={ask(name, dialog)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
