#!/usr/bin/python3
"""Configure NodeBB on PostgreSQL at the first boot (handbook note 0082).

Options:
    --domain=   the domain of the forum; url is https://DOMAIN
    --email=    the email of the admin user (default admin@DOMAIN)
    --admin=    the login of the admin user (default admin)

Environment:
    APP_PASS       the password of the admin user (secrets.app_password)
    DB_PASS        the password of the role nodebb (secrets.db_password of
                   lnpp, which a pair shares)
    NODEBB_SECRET  the secret that signs the session cookie; when it is
                   not set, the secret of an existing config.json stays,
                   else the hook makes a new one

On the node whose PostgreSQL accepts writes (simple, or the primary of a
pair) the hook sets the role nodebb and its password, makes the database
nodebb, writes config.json and runs `./nodebb setup`. On a standby it
writes config.json only: the database comes from the primary. The
passwords go to psql on standard input and to NodeBB in the environment,
never in the arguments, which the process list shows. At its end the hook
writes READY, and only then does serve.py start NodeBB.
"""

import base64
import getopt
import hashlib
import hmac
import json
import os
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
SCRAM_ITERATIONS = 4096
DOMAIN_RE = re.compile(
    r"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9._-]{2,32}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+$")
# NodeBB 4 reads these keys (src/prestart.js, src/install.js)
DATABASE_SQL = """\
SELECT 'CREATE ROLE nodebb LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nodebb')\\gexec
ALTER ROLE nodebb LOGIN PASSWORD '%s';
SELECT 'CREATE DATABASE nodebb OWNER nodebb ENCODING ''UTF8'' TEMPLATE template0'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nodebb')\\gexec
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


def scram_verifier(password, salt=None, iterations=SCRAM_ITERATIONS):
    """The SCRAM-SHA-256 verifier that PostgreSQL stores (RFC 7677). The
    server accepts it in ALTER ROLE ... PASSWORD and never sees the
    password itself."""
    salt = salt if salt is not None else secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", "sha256").digest()
    b64 = lambda data: base64.b64encode(data).decode()  # noqa: E731
    return "SCRAM-SHA-256$%d:%s$%s:%s" % (iterations, b64(salt), b64(stored_key), b64(server_key))


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


def set_database(db_pass, run=subprocess.run):
    verifier = scram_verifier(db_pass)
    run_postgres(["-d", "postgres"], stdin=DATABASE_SQL % verifier, run=run)


def read_config(path=CONFIG):
    try:
        with open(path) as conf:
            return json.load(conf)
    except FileNotFoundError:
        return {}
    except ValueError as error:
        raise HookError("%s is not JSON: %s" % (path, error))


def build_config(domain, db_pass, secret):
    return {
        "url": "https://%s" % domain,
        "secret": secret,
        "database": "postgres",
        "postgres": {
            "host": "127.0.0.1",
            "port": 5432,
            "username": DATABASE,
            "password": db_pass,
            "database": DATABASE,
            "ssl": False,
        },
        "port": PORT,
        "bind_address": "127.0.0.1",
        "trust_proxy": True,
        "upload_path": UPLOADS,
        "acpPluginInstallDisabled": True,
    }


def write_config(config, owner, path=CONFIG, chown=os.chown):
    """Write config.json with mode 0640, owned by OWNER (uid, gid), in one
    rename, so NodeBB never reads half a file."""
    tmp = path + ".keel-new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w") as out:
        json.dump(config, out, indent=4)
        out.write("\n")
    chown(tmp, *owner)
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def setup_command(nodebb_dir=NODEBB_DIR):
    """./nodebb setup; with the assets of the image, no build."""
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
    result = run(setup_command(), cwd=NODEBB_DIR, env=setup_env(admin, password, email), check=False)
    if result.returncode != 0:
        raise HookError("./nodebb setup failed with exit %d" % result.returncode)


def owner_of(user):
    entry = pwd.getpwnam(user)
    return entry.pw_uid, entry.pw_gid


def mark_ready(path=READY):
    with open(path, "w"):
        pass


def configure(values, env, run=subprocess.run, chown=os.chown, owner=owner_of):
    domain = given(values.get("domain"))
    if not domain or not DOMAIN_RE.match(domain):
        raise HookError("the domain %r is not a host name" % domain)
    admin = given(values.get("admin")) or "admin"
    if not LOGIN_RE.match(admin):
        raise HookError("the admin login %r has a character that NodeBB refuses" % admin)
    email = given(values.get("email")) or "admin@%s" % domain.strip("[]").split(":")[0]
    if not EMAIL_RE.match(email):
        raise HookError("the admin email %r is not an address" % email)
    password = given(env.get("APP_PASS"))
    db_pass = given(env.get("DB_PASS"))
    if not db_pass:
        raise HookError("no DB_PASS: the role nodebb needs the password of the database")
    secret = given(env.get("NODEBB_SECRET")) or read_config().get("secret") or secrets.token_hex(32)
    config = build_config(domain, db_pass, secret)
    uid, gid = owner(SERVICE_USER)
    writable = is_writable(run=run)
    if writable:
        if not password:
            raise HookError("no APP_PASS: the admin user of NodeBB needs a password")
        set_database(db_pass, run=run)
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
        writable = configure(values, os.environ if env is None else env)
        mark_ready()
    except (HookError, OSError, KeyError) as error:
        print("nodebb.py: %s" % error, file=sys.stderr)
        return 1
    print("NodeBB is configured (%s)" % ("writable node: database and setup" if writable
                                          else "standby: config.json only"))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
