#!/usr/bin/python3
"""Configure NodeBB on PostgreSQL at the first boot (handbook note 0082).

Options:
    --domain=   the domain of the forum; url is https://DOMAIN
    --email=    the email of the admin user (default admin@DOMAIN)
    --admin=    the login of the admin user (default admin)

Environment:
    APP_PASS       the password of the admin user (secrets.app_password).
                   With no APP_PASS and a terminal on standard input, the
                   hook asks it on the console (the screen 'NodeBB
                   password')
    KEEL_SECRET_NODEBB_SECRET
                   the secret that signs the session cookie, when the spec
                   declares secrets.nodebb_secret (keel renders a manifest
                   secret with the prefix KEEL_SECRET_)

On the node whose PostgreSQL accepts writes (simple, or the primary of a
pair) the hook makes the role nodebb and the database nodebb, writes
config.json and runs `./nodebb setup`. On a standby it writes config.json
only: the database comes from the primary. The admin password goes to
NodeBB in the environment, never in the arguments, which the process list
shows. At its end the hook writes READY, and only then does serve.py start
NodeBB.

NodeBB logs in to PostgreSQL on the socket of the server, with the peer
authentication of the operating system user nodebb, as serve.py does. So
the role nodebb has no password, config.json holds no database password,
and the hook does not need DB_PASS. An interactive first boot does not
have DB_PASS: 35pgsqlpass asks the password of postgres on the console
and gives it to no later hook (lxc-interactive and vm-iso, 2026-11-12).

The session secret lives in the database, in the one-row table
keel_nodebb_secret, so a pair shares it with the session rows, as
WordPress keeps its salts in its database. The first writable boot writes
the row: the secret of the spec, else a new one. No later boot changes
it. serve.py gives the secret of the row to NodeBB in its environment,
which NodeBB reads before config.json.

NodeBB needs a CPU of the x86-64-v2 level on x86_64: its image library
sharp loads its linux-x64 binary only there, and the WebAssembly build of
sharp needs SSE4.1 too. On the CPU model kvm64, the default of `qm create`,
`./nodebb setup` stopped with 'Could not load the "sharp" module ...
Prebuilt binaries for Linux x64 require v2 microarchitecture', and the
forum answered 502 (vm-iso of 19.0-8, VM 9448, BR1, 2026-11-12). So the
hook checks the flags of /proc/cpuinfo first. On such a CPU it changes
nothing, asks nothing, and says what to change.
"""

import getopt
import json
import os
import platform
import pwd
import re
import secrets
import subprocess
import sys

NODEBB_DIR = "/var/www/nodebb"
CONFIG = NODEBB_DIR + "/config.json"
READY = "/var/lib/keel-nodebb/ready"
UPLOADS = "/var/lib/nodebb/uploads"
SERVICE_USER = "nodebb"
DATABASE = "nodebb"
PORT = 4567
# the directory of the socket of PostgreSQL (unix_socket_directories of
# Debian); node-postgres takes a host that starts with "/" as a socket
# directory
SOCKET_DIR = "/run/postgresql"
CPUINFO = "/proc/cpuinfo"
# the x86-64-v2 level (sharp 0.35, _isUsingX64V2), as /proc/cpuinfo names
# the flags: pni is SSE3
X86_64_V2 = ("cx16", "lahf_lm", "pni", "popcnt", "sse4_1", "sse4_2", "ssse3")
DIALOG_TITLE = "Keel Linux - First boot configuration"
DOMAIN_RE = re.compile(
    r"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9._-]{2,32}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+$")
# NodeBB 4 reads these keys (src/prestart.js, src/install.js)
DATABASE_SQL = """\
SELECT 'CREATE ROLE nodebb LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nodebb')\\gexec
ALTER ROLE nodebb LOGIN PASSWORD NULL;
SELECT 'CREATE DATABASE nodebb OWNER nodebb ENCODING ''UTF8'' TEMPLATE template0'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nodebb')\\gexec
"""
# The row is written one time: ON CONFLICT DO NOTHING keeps the secret of
# the first writable boot. The output is the secret that the row holds.
SECRET_SQL = """\
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS keel_nodebb_secret (
  id smallint PRIMARY KEY CHECK (id = 1), secret text NOT NULL CHECK (secret <> ''));
ALTER TABLE keel_nodebb_secret OWNER TO nodebb;
REVOKE ALL ON keel_nodebb_secret FROM PUBLIC;
INSERT INTO keel_nodebb_secret (id, secret) VALUES (1, '%s') ON CONFLICT (id) DO NOTHING;
SELECT secret FROM keel_nodebb_secret WHERE id = 1;
"""


class HookError(Exception):
    """A failure that the hook reports on stderr and ends with exit 1."""


def usage(message=None):
    if message:
        print("Error:", message, file=sys.stderr)
    print("Syntax: %s [options]" % sys.argv[0], file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    try:
        opts, _ = getopt.gnu_getopt(argv, "h", ["help", "domain=", "email=", "admin="])
    except getopt.GetoptError as error:
        usage(error)
    values = {"domain": None, "email": None, "admin": None}
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        values[opt[2:]] = val
    return values


def given(value):
    """The value, or None for an empty one or the inithooks placeholder."""
    if not value or value.upper() == "DEFAULT":
        return None
    return value


def load_dialog():
    from libinithooks.dialog_wrapper import Dialog
    return Dialog


def read_password(env, interactive):
    """APP_PASS, else the answer of the console, as odoo.py of keel-odoo"""
    password = given(env.get("APP_PASS"))
    if password:
        return password
    if not interactive:
        raise HookError("no APP_PASS: the admin user of NodeBB needs a password; "
                        "declare secrets.app_password, or run keel-init on a console")
    dialog = load_dialog()(DIALOG_TITLE)
    return dialog.get_password(
        "NodeBB password",
        "Enter the password for the NodeBB 'admin' user.")


def run_postgres(args, stdin=None, run=subprocess.run):
    """psql as the operating system user postgres, on the socket."""
    result = run(["/usr/sbin/runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-At",
                  "-v", "ON_ERROR_STOP=1"] + args,
                 input=stdin, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise HookError("psql failed: %s" % result.stderr.strip())
    return result.stdout.strip()


def is_writable(run=subprocess.run):
    out = run_postgres(["-c", "SELECT pg_is_in_recovery()"], run=run)
    return out == "f"


def set_database(run=subprocess.run):
    run_postgres(["-d", "postgres"], stdin=DATABASE_SQL, run=run)


def store_secret(candidate, run=subprocess.run):
    """The secret of the row, which the first writable boot writes"""
    out = run_postgres(["-d", DATABASE], stdin=SECRET_SQL % candidate.replace("'", "''"), run=run)
    lines = out.splitlines()
    if not lines or not lines[-1]:
        raise HookError("the table keel_nodebb_secret gave no secret")
    return lines[-1]


def missing_cpu_flags(path=None, machine=None):
    """The flags of the x86-64-v2 level that the CPU does not have, sorted.
    Empty on another architecture."""
    if (machine or platform.machine)() != "x86_64":
        return []
    have = set()
    with open(path or CPUINFO) as info:
        for line in info:
            key, _, value = line.partition(":")
            if key.strip() == "flags":
                have.update(value.split())
                break
    return sorted(set(X86_64_V2) - have)


def check_cpu():
    missing = missing_cpu_flags()
    if missing:
        raise HookError(
            "this CPU is not of the x86-64-v2 level (it has no %s), and the image "
            "library of NodeBB needs that level. On Proxmox VE, set the CPU type of "
            "the VM to x86-64-v2-AES (the default of the web interface) or host, start "
            "the VM again, and run /usr/lib/inithooks/firstboot.d/45nodebb as root"
            % " ".join(missing))


def read_config(path=None):
    path = path or CONFIG
    try:
        with open(path) as conf:
            return json.load(conf)
    except FileNotFoundError:
        return {}
    except ValueError as error:
        raise HookError("%s is not JSON: %s" % (path, error))


def build_config(domain, secret):
    return {
        "url": "https://%s" % domain,
        "secret": secret,
        "database": "postgres",
        "postgres": {
            "host": SOCKET_DIR,
            "port": 5432,
            "username": DATABASE,
            "database": DATABASE,
            "ssl": False,
        },
        "port": PORT,
        "bind_address": "127.0.0.1",
        "trust_proxy": True,
        "upload_path": UPLOADS,
        "acpPluginInstallDisabled": True,
    }


def write_config(config, owner, path=None, chown=os.chown):
    """Write config.json with mode 0640, owned by OWNER (uid, gid), in one
    rename, so NodeBB never reads half a file."""
    path = path or CONFIG
    tmp = path + ".keel-new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w") as out:
        json.dump(config, out, indent=4)
        out.write("\n")
    chown(tmp, *owner)
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def setup_command(nodebb_dir=None):
    """./nodebb setup; with the assets of the image, no build."""
    nodebb_dir = nodebb_dir or NODEBB_DIR
    command = ["/usr/sbin/runuser", "-u", SERVICE_USER, "--", "./nodebb", "setup"]
    if os.path.isdir(os.path.join(nodebb_dir, "build", "public")):
        command.append("--skip-build")
    return command


def setup_env(admin, password, email):
    """A clean environment: NodeBB maps every variable that starts with
    NODEBB_ to a setup value (src/install.js, checkSetupFlagEnv)."""
    return {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": "/var/lib/nodebb",
        "NODE_ENV": "production",
        "NODEBB_ADMIN_USERNAME": admin,
        "NODEBB_ADMIN_PASSWORD": password,
        "NODEBB_ADMIN_EMAIL": email,
    }


def run_setup(admin, password, email, run=subprocess.run):
    """Standard input is not the console: a question of the setup gets no
    answer and fails, and never holds the first boot."""
    result = run(setup_command(), cwd=NODEBB_DIR, env=setup_env(admin, password, email),
                 stdin=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        raise HookError("./nodebb setup failed with exit %d" % result.returncode)


def owner_of(user):
    entry = pwd.getpwnam(user)
    return entry.pw_uid, entry.pw_gid


def make_uploads(owner, path=None, chown=os.chown):
    """uploads/system: the setup copies the favicon there and makes no
    directory for it (src/install.js, CT 9385, 2026-11-11). Every other
    upload makes its own directory (src/file.js)."""
    system = os.path.join(path or UPLOADS, "system")
    os.makedirs(system, exist_ok=True)
    # makedirs applies the umask to its mode
    os.chmod(system, 0o755)
    chown(system, *owner)


def mark_ready(path=None):
    with open(path or READY, "w"):
        pass


def host_of(domain):
    """The domain without its port: [2001:db8::1]:8443 gives [2001:db8::1]."""
    if domain.startswith("["):
        return domain[:domain.index("]") + 1]
    return domain.split(":")[0]


def configure(values, env, run=subprocess.run, chown=os.chown, owner=owner_of, interactive=False):
    check_cpu()
    domain = given(values.get("domain"))
    if not domain or not DOMAIN_RE.match(domain):
        raise HookError("the domain %r is not a host name" % domain)
    admin = given(values.get("admin")) or "admin"
    if not LOGIN_RE.match(admin):
        raise HookError("the admin login %r has a character that NodeBB refuses" % admin)
    email = given(values.get("email")) or "admin@%s" % host_of(domain)
    if not EMAIL_RE.match(email):
        raise HookError("the admin email %r is not an address" % email)
    spec_secret = given(env.get("KEEL_SECRET_NODEBB_SECRET"))
    uid, gid = owner(SERVICE_USER)
    writable = is_writable(run=run)
    if writable:
        password = read_password(env, interactive)
        set_database(run=run)
        secret = store_secret(spec_secret or secrets.token_hex(32), run=run)
    else:
        # serve.py never starts NodeBB here: after a promote it gives the
        # secret of the replicated row in the environment
        secret = spec_secret or read_config().get("secret") or secrets.token_hex(32)
    config = build_config(domain, secret)
    if writable:
        make_uploads((uid, gid), chown=chown)
        # setup runs as nodebb and rewrites config.json, so nodebb owns it
        # while setup runs
        write_config(config, (uid, gid), chown=chown)
        run_setup(admin, password, email, run=run)
    # the final file: root owns it, nodebb reads it and cannot change it
    write_config(config, (0, gid), chown=chown)
    return writable


def main(argv=None, env=None):
    values = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        writable = configure(values, os.environ if env is None else env,
                             interactive=sys.stdin.isatty())
        mark_ready()
    except (HookError, OSError, KeyError) as error:
        print("nodebb.py: %s" % error, file=sys.stderr)
        return 1
    print("NodeBB is configured (%s)" % ("writable node: database and setup" if writable
                                          else "standby: config.json only"))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
