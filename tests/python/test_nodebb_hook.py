"""Tests of usr/lib/inithooks/bin/nodebb.py, the first boot program of
NodeBB (handbook note 0082, section 5). psql, runuser and ./nodebb are
fakes; the paths go to a temporary directory."""
import base64
import hashlib
import hmac
import json
import os

import pytest


class Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class Fake:
    """subprocess.run of the hook: psql as postgres and ./nodebb setup."""

    def __init__(self, recovery="f", setup_code=0, psql_code=0):
        self.recovery = recovery
        self.setup_code = setup_code
        self.psql_code = psql_code
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if "psql" in argv:
            if self.psql_code:
                return Result(self.psql_code, "", "role error\n")
            if "SELECT pg_is_in_recovery()" in argv:
                return Result(0, self.recovery + "\n")
            return Result(0, "")
        return Result(self.setup_code)

    def psql_stdin(self):
        return [k.get("input") for a, k in self.calls if "psql" in a and k.get("input")]

    def setups(self):
        return [(a, k) for a, k in self.calls if "setup" in a]


@pytest.fixture
def paths(hook, tmp_path, monkeypatch):
    nodebb = tmp_path / "nodebb"
    nodebb.mkdir()
    monkeypatch.setattr(hook, "NODEBB_DIR", str(nodebb))
    monkeypatch.setattr(hook, "CONFIG", str(nodebb / "config.json"))
    monkeypatch.setattr(hook, "READY", str(tmp_path / "ready"))
    monkeypatch.setattr(hook, "UPLOADS", str(tmp_path / "uploads"))
    return tmp_path


ENV = {"APP_PASS": "admin-secret", "DB_PASS": "db-secret"}
VALUES = {"domain": "forum.example.org", "email": None, "admin": None}


def chowns():
    calls = []
    return calls, lambda path, uid, gid: calls.append((os.path.basename(path), uid, gid))


def test_given(hook):
    assert hook.given(None) is None
    assert hook.given("") is None
    assert hook.given("default") is None
    assert hook.given("x") == "x"


def test_parse_args(hook):
    assert hook.parse_args(["--domain=a.org", "--email=b@a.org", "--admin=boss"]) == \
        {"domain": "a.org", "email": "b@a.org", "admin": "boss"}
    with pytest.raises(SystemExit):
        hook.parse_args(["--bogus"])
    with pytest.raises(SystemExit):
        hook.parse_args(["-h"])


def test_usage_prints_the_message(hook, capsys):
    with pytest.raises(SystemExit):
        hook.usage("bad")
    assert "Error: bad" in capsys.readouterr().err


def test_scram_verifier_is_the_rfc_7677_form(hook):
    salt = b"0123456789abcdef"
    out = hook.scram_verifier("pencil", salt=salt, iterations=4096)
    head, keys = out.split("$", 1)[1].split("$")
    iterations, salt_b64 = head.split(":")
    stored_b64, server_b64 = keys.split(":")
    assert out.startswith("SCRAM-SHA-256$4096:")
    assert base64.b64decode(salt_b64) == salt
    salted = hashlib.pbkdf2_hmac("sha256", b"pencil", salt, 4096)
    client = hmac.new(salted, b"Client Key", "sha256").digest()
    assert base64.b64decode(stored_b64) == hashlib.sha256(client).digest()
    assert base64.b64decode(server_b64) == hmac.new(salted, b"Server Key", "sha256").digest()
    assert hook.scram_verifier("pencil") != hook.scram_verifier("pencil")


def test_writable_node_sets_the_database_writes_config_and_runs_setup(hook, paths):
    run, (calls, chown) = Fake(), chowns()
    assert hook.configure(VALUES, ENV, run=run, chown=chown, owner=lambda u: (111, 222)) is True
    sql = run.psql_stdin()[0]
    assert "CREATE ROLE nodebb LOGIN" in sql
    assert "PASSWORD 'SCRAM-SHA-256$4096:" in sql
    assert "db-secret" not in sql
    assert "CREATE DATABASE nodebb OWNER nodebb" in sql
    argv, kwargs = run.setups()[0]
    assert argv[:5] == ["/usr/sbin/runuser", "-u", "nodebb", "--", "./nodebb"]
    assert "admin-secret" not in " ".join(argv)
    assert kwargs["env"]["NODEBB_ADMIN_PASSWORD"] == "admin-secret"
    assert kwargs["env"]["NODEBB_ADMIN_USERNAME"] == "admin"
    assert kwargs["env"]["NODEBB_ADMIN_EMAIL"] == "admin@forum.example.org"
    assert not [k for k in kwargs["env"] if k.startswith("NODEBB_") and not k.startswith("NODEBB_ADMIN_")]
    for argv, _ in run.calls:
        assert "db-secret" not in " ".join(argv)
    conf = json.loads((paths / "nodebb" / "config.json").read_text())
    assert conf["url"] == "https://forum.example.org"
    assert conf["database"] == "postgres"
    assert conf["postgres"] == {"host": "127.0.0.1", "port": 5432, "username": "nodebb",
                                "password": "db-secret", "database": "nodebb", "ssl": False}
    assert conf["port"] == 4567 and conf["bind_address"] == "127.0.0.1"
    assert conf["upload_path"] == str(paths / "uploads")
    assert conf["acpPluginInstallDisabled"] is True
    assert len(conf["secret"]) == 64
    assert oct(os.stat(paths / "nodebb" / "config.json").st_mode & 0o777) == "0o640"
    # nodebb owns config.json while setup runs, root owns it at the end
    assert calls[-2:] == [("config.json.keel-new", 111, 222), ("config.json.keel-new", 0, 222)]
    assert ("system", 111, 222) in calls
    assert oct(os.stat(paths / "uploads" / "system").st_mode & 0o777) == "0o755"


def test_setup_skips_the_build_when_the_image_has_the_assets(hook, paths):
    (paths / "nodebb" / "build" / "public").mkdir(parents=True)
    run = Fake()
    hook.configure(VALUES, ENV, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    assert run.setups()[0][0][-1] == "--skip-build"


def test_standby_writes_config_only(hook, paths):
    run, (calls, chown) = Fake(recovery="t"), chowns()
    assert hook.configure(VALUES, {"DB_PASS": "db-secret"}, run=run, chown=chown,
                          owner=lambda u: (1, 2)) is False
    assert run.psql_stdin() == []
    assert run.setups() == []
    assert calls == [("config.json.keel-new", 0, 2)]
    assert json.loads((paths / "nodebb" / "config.json").read_text())["postgres"]["password"] == "db-secret"


def test_the_secret_of_the_spec_or_of_the_old_config_stays(hook, paths):
    env = dict(ENV, NODEBB_SECRET="from-the-spec")
    hook.configure(VALUES, env, run=Fake(), chown=lambda *a: None, owner=lambda u: (1, 2))
    assert json.loads((paths / "nodebb" / "config.json").read_text())["secret"] == "from-the-spec"
    hook.configure(VALUES, ENV, run=Fake(), chown=lambda *a: None, owner=lambda u: (1, 2))
    assert json.loads((paths / "nodebb" / "config.json").read_text())["secret"] == "from-the-spec"


def test_values_of_the_spec(hook, paths):
    run = Fake()
    values = {"domain": "[2001:db8::1]:8443", "email": "boss@example.org", "admin": "boss"}
    hook.configure(values, ENV, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    env = run.setups()[0][1]["env"]
    assert env["NODEBB_ADMIN_USERNAME"] == "boss"
    assert env["NODEBB_ADMIN_EMAIL"] == "boss@example.org"
    assert json.loads((paths / "nodebb" / "config.json").read_text())["url"] == "https://[2001:db8::1]:8443"


def test_an_ipv6_domain_gives_a_default_email(hook, paths):
    # the first version gave admin@2001
    run = Fake()
    hook.configure({"domain": "[2001:db8::1]:8443"}, ENV, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    assert run.setups()[0][1]["env"]["NODEBB_ADMIN_EMAIL"] == "admin@[2001:db8::1]"


@pytest.mark.parametrize("values,env,message", [
    ({"domain": None}, ENV, "is not a host name"),
    ({"domain": "bad domain"}, ENV, "is not a host name"),
    ({"domain": "a.org", "admin": "bad admin"}, ENV, "admin login"),
    ({"domain": "a.org", "email": "not-an-address"}, ENV, "admin email"),
    ({"domain": "a.org"}, {"APP_PASS": "x"}, "no DB_PASS"),
    ({"domain": "a.org"}, {"DB_PASS": "x"}, "no APP_PASS"),
])
def test_refusals(hook, paths, values, env, message):
    with pytest.raises(hook.HookError, match=message):
        hook.configure(values, env, run=Fake(), chown=lambda *a: None, owner=lambda u: (1, 2))


def test_a_failed_psql_or_setup_is_an_error(hook, paths):
    with pytest.raises(hook.HookError, match="psql failed: role error"):
        hook.configure(VALUES, ENV, run=Fake(psql_code=1), chown=lambda *a: None, owner=lambda u: (1, 2))
    with pytest.raises(hook.HookError, match="setup failed with exit 3"):
        hook.configure(VALUES, ENV, run=Fake(setup_code=3), chown=lambda *a: None, owner=lambda u: (1, 2))


def test_a_config_that_is_not_json_is_an_error(hook, paths):
    (paths / "nodebb" / "config.json").write_text("{not json")
    with pytest.raises(hook.HookError, match="is not JSON"):
        hook.read_config(str(paths / "nodebb" / "config.json"))


def test_read_config_of_a_missing_file(hook, tmp_path):
    assert hook.read_config(str(tmp_path / "none.json")) == {}


def test_owner_of(hook):
    assert hook.owner_of("root") == (0, 0)


def test_main_writes_ready_and_reports(hook, paths, monkeypatch, capsys):
    monkeypatch.setattr(hook, "configure", lambda values, env: True)
    assert hook.main(["--domain=a.org"], env={}) == 0
    assert (paths / "ready").exists()
    assert "writable node" in capsys.readouterr().out
    monkeypatch.setattr(hook, "configure", lambda values, env: False)
    assert hook.main(["--domain=a.org"], env={}) == 0
    assert "standby" in capsys.readouterr().out


def test_main_reports_a_failure_and_writes_no_ready(hook, paths, monkeypatch, capsys):
    def fail(values, env):
        raise hook.HookError("broken")
    monkeypatch.setattr(hook, "configure", fail)
    assert hook.main(["--domain=a.org"], env={}) == 1
    assert "nodebb.py: broken" in capsys.readouterr().err
    assert not (paths / "ready").exists()


def test_main_reads_the_process_environment(hook, paths, monkeypatch):
    seen = {}
    monkeypatch.setattr(hook, "configure", lambda values, env: seen.update(env=env) or True)
    monkeypatch.setattr(hook.sys, "argv", ["nodebb.py", "--domain=a.org"])
    assert hook.main() == 0
    assert seen["env"] is os.environ


def test_the_default_upload_path_is_the_replicated_one(hook):
    assert hook.UPLOADS == "/var/lib/nodebb/uploads"
    assert hook.build_config("a.org", "p", "s")["upload_path"] == "/var/lib/nodebb/uploads"
