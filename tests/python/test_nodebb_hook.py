"""Tests of usr/lib/inithooks/bin/nodebb.py, the first boot program of
NodeBB (handbook note 0082, section 5). psql, runuser and ./nodebb are
fakes; the paths go to a temporary directory."""
import json
import os
import subprocess

import pytest


class Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class Fake:
    """subprocess.run of the hook: psql as postgres and ./nodebb setup."""

    def __init__(self, recovery="f", setup_code=0, psql_code=0, row=None):
        self.recovery = recovery
        # the secret that keel_nodebb_secret holds already, or None
        self.row = row
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
            sql = kwargs.get("input") or ""
            if "keel_nodebb_secret" in sql:
                if self.row is None:
                    value = sql.split("VALUES (1, '", 1)[1].split("') ON CONFLICT", 1)[0]
                    self.row = value.replace("''", "'")
                return Result(0, self.row + "\n")
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
    cpuinfo = tmp_path / "cpuinfo"
    cpuinfo.write_text(cpu(V2_FLAGS))
    monkeypatch.setattr(hook, "CPUINFO", str(cpuinfo))
    return tmp_path


# the flags of the x86-64-v2 level, as /proc/cpuinfo names them
V2_FLAGS = "fpu sse sse2 pni ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm"
# the CPU model kvm64, the default of `qm create` (VM 9448, BR1, 2026-11-12)
KVM64_FLAGS = "fpu sse sse2 pni cx16 lahf_lm"


def cpu(flags, cores=2):
    return "".join("processor\t: %d\nmodel name\t: Common KVM processor\nflags\t\t: %s\n\n"
                   % (n, flags) for n in range(cores))


# DB_PASS is in the environment of a preseeded first boot: the hook must
# not use it, as an interactive first boot does not have it (lxc-interactive
# and vm-iso of 2026-11-12)
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


def test_writable_node_sets_the_database_writes_config_and_runs_setup(hook, paths):
    run, (calls, chown) = Fake(), chowns()
    assert hook.configure(VALUES, ENV, run=run, chown=chown, owner=lambda u: (111, 222)) is True
    sql = run.psql_stdin()[0]
    assert "CREATE ROLE nodebb LOGIN" in sql
    # peer authentication on the socket only: the role has no password
    assert "ALTER ROLE nodebb LOGIN PASSWORD NULL;" in sql
    assert "db-secret" not in sql
    assert "CREATE DATABASE nodebb OWNER nodebb" in sql
    argv, kwargs = run.setups()[0]
    assert argv[:5] == ["/usr/sbin/runuser", "-u", "nodebb", "--", "./nodebb"]
    assert "admin-secret" not in " ".join(argv)
    assert kwargs["env"]["NODEBB_ADMIN_PASSWORD"] == "admin-secret"
    # the setup never reads the console that the dialog of the hook uses
    assert kwargs["stdin"] is subprocess.DEVNULL
    assert kwargs["env"]["NODEBB_ADMIN_USERNAME"] == "admin"
    assert kwargs["env"]["NODEBB_ADMIN_EMAIL"] == "admin@forum.example.org"
    assert not [k for k in kwargs["env"] if k.startswith("NODEBB_") and not k.startswith("NODEBB_ADMIN_")]
    for argv, _ in run.calls:
        assert "db-secret" not in " ".join(argv)
    conf = json.loads((paths / "nodebb" / "config.json").read_text())
    assert conf["url"] == "https://forum.example.org"
    assert conf["database"] == "postgres"
    # the socket of PostgreSQL, so config.json holds no database password
    assert conf["postgres"] == {"host": "/run/postgresql", "port": 5432, "username": "nodebb",
                                "database": "nodebb", "ssl": False}
    assert "db-secret" not in (paths / "nodebb" / "config.json").read_text()
    assert conf["port"] == 4567 and conf["bind_address"] == "127.0.0.1"
    assert conf["upload_path"] == str(paths / "uploads")
    assert conf["acpPluginInstallDisabled"] is True
    assert len(conf["secret"]) == 64
    # the row holds the secret of config.json, and the SQL goes on standard input
    assert run.row == conf["secret"]
    assert "ON CONFLICT (id) DO NOTHING" in run.psql_stdin()[1]
    for argv, _ in run.calls:
        assert conf["secret"] not in " ".join(argv)
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
    assert hook.configure(VALUES, {}, run=run, chown=chown,
                          owner=lambda u: (1, 2)) is False
    assert run.psql_stdin() == []
    assert run.setups() == []
    assert calls == [("config.json.keel-new", 0, 2)]
    assert "password" not in json.loads((paths / "nodebb" / "config.json").read_text())["postgres"]


def test_the_secret_of_the_spec_goes_into_the_row(hook, paths):
    run = Fake()
    env = dict(ENV, KEEL_SECRET_NODEBB_SECRET="it's-from-the-spec")
    hook.configure(VALUES, env, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    assert run.row == "it's-from-the-spec"
    assert "'it''s-from-the-spec'" in run.psql_stdin()[1]
    assert json.loads((paths / "nodebb" / "config.json").read_text())["secret"] == "it's-from-the-spec"


def test_a_second_boot_keeps_the_row(hook, paths):
    # the row exists: neither a new secret nor the spec's replaces it
    run = Fake(row="first-secret")
    env = dict(ENV, KEEL_SECRET_NODEBB_SECRET="another")
    hook.configure(VALUES, env, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    assert run.row == "first-secret"
    assert json.loads((paths / "nodebb" / "config.json").read_text())["secret"] == "first-secret"


def test_a_row_with_no_secret_is_an_error(hook, paths):
    with pytest.raises(hook.HookError, match="gave no secret"):
        hook.configure(VALUES, ENV, run=Fake(row=""), chown=lambda *a: None, owner=lambda u: (1, 2))


def test_a_standby_takes_the_secret_of_the_spec_or_of_the_old_config(hook, paths):
    env = {"KEEL_SECRET_NODEBB_SECRET": "from-the-spec"}
    run = Fake(recovery="t")
    hook.configure(VALUES, env, run=run, chown=lambda *a: None, owner=lambda u: (1, 2))
    assert run.row is None
    assert json.loads((paths / "nodebb" / "config.json").read_text())["secret"] == "from-the-spec"
    hook.configure(VALUES, {}, run=Fake(recovery="t"), chown=lambda *a: None, owner=lambda u: (1, 2))
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
    ({"domain": "a.org"}, {"DB_PASS": "x"}, "no APP_PASS"),
    ({"domain": "a.org"}, {"APP_PASS": "DEFAULT"}, "no APP_PASS"),
])
def test_refusals(hook, paths, values, env, message):
    with pytest.raises(hook.HookError, match=message):
        hook.configure(values, env, run=Fake(), chown=lambda *a: None, owner=lambda u: (1, 2))


def test_no_db_pass_is_needed(hook, paths):
    # an interactive first boot: 35pgsqlpass asked the password of postgres
    # on the console, and no hook after it has DB_PASS
    run = Fake()
    assert hook.configure(VALUES, {"APP_PASS": "admin-secret"}, run=run,
                          chown=lambda *a: None, owner=lambda u: (1, 2)) is True
    assert run.setups()


class Dialog:
    """libinithooks.dialog_wrapper.Dialog: it records the screens"""
    asked = []

    def __init__(self, title):
        self.title = title

    def get_password(self, title, text, **kwargs):
        Dialog.asked.append((self.title, title, text))
        return "typed-secret"


def test_a_console_asks_the_nodebb_password(hook, paths, monkeypatch):
    Dialog.asked = []
    monkeypatch.setattr(hook, "load_dialog", lambda: Dialog)
    run = Fake()
    hook.configure(VALUES, {}, run=run, chown=lambda *a: None, owner=lambda u: (1, 2), interactive=True)
    # the title is the prompt of the contract (tests/commission.yaml)
    assert [a[:2] for a in Dialog.asked] == [("Keel Linux - First boot configuration", "NodeBB password")]
    assert "'admin'" in Dialog.asked[0][2]
    assert run.setups()[0][1]["env"]["NODEBB_ADMIN_PASSWORD"] == "typed-secret"


def test_a_console_asks_nothing_when_the_password_is_declared(hook, paths, monkeypatch):
    Dialog.asked = []
    monkeypatch.setattr(hook, "load_dialog", lambda: Dialog)
    hook.configure(VALUES, ENV, run=Fake(), chown=lambda *a: None, owner=lambda u: (1, 2), interactive=True)
    assert Dialog.asked == []


def test_a_standby_asks_nothing(hook, paths, monkeypatch):
    # the standby takes the admin user of the primary with the database
    Dialog.asked = []
    monkeypatch.setattr(hook, "load_dialog", lambda: Dialog)
    hook.configure(VALUES, {}, run=Fake(recovery="t"), chown=lambda *a: None, owner=lambda u: (1, 2),
                   interactive=True)
    assert Dialog.asked == []


def test_load_dialog_names_the_inithooks_class(hook, monkeypatch):
    import sys
    import types
    package = types.ModuleType("libinithooks")
    fake = types.ModuleType("libinithooks.dialog_wrapper")
    fake.Dialog = object
    monkeypatch.setitem(sys.modules, "libinithooks", package)
    monkeypatch.setitem(sys.modules, "libinithooks.dialog_wrapper", fake)
    assert hook.load_dialog() is object


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
    monkeypatch.setattr(hook, "configure", lambda values, env, interactive: True)
    assert hook.main(["--domain=a.org"], env={}) == 0
    assert (paths / "ready").exists()
    assert "writable node" in capsys.readouterr().out
    monkeypatch.setattr(hook, "configure", lambda values, env, interactive: False)
    assert hook.main(["--domain=a.org"], env={}) == 0
    assert "standby" in capsys.readouterr().out


def test_main_reports_a_failure_and_writes_no_ready(hook, paths, monkeypatch, capsys):
    def fail(values, env, interactive):
        raise hook.HookError("broken")
    monkeypatch.setattr(hook, "configure", fail)
    assert hook.main(["--domain=a.org"], env={}) == 1
    assert "nodebb.py: broken" in capsys.readouterr().err
    assert not (paths / "ready").exists()


def test_main_reads_the_process_environment(hook, paths, monkeypatch):
    seen = {}
    monkeypatch.setattr(hook, "configure",
                        lambda values, env, interactive: seen.update(env=env, interactive=interactive) or True)
    monkeypatch.setattr(hook.sys, "argv", ["nodebb.py", "--domain=a.org"])
    monkeypatch.setattr(hook.sys, "stdin", type("Stdin", (), {"isatty": lambda self: True})())
    assert hook.main() == 0
    assert seen["env"] is os.environ
    # a terminal on standard input is the console that the dialog uses
    assert seen["interactive"] is True


def test_the_default_upload_path_is_the_replicated_one(hook):
    assert hook.UPLOADS == "/var/lib/nodebb/uploads"
    assert hook.build_config("a.org", "s")["upload_path"] == "/var/lib/nodebb/uploads"


def test_missing_cpu_flags_of_a_v2_cpu_is_empty(hook, tmp_path):
    info = tmp_path / "cpuinfo"
    info.write_text(cpu(V2_FLAGS))
    assert hook.missing_cpu_flags(str(info), machine=lambda: "x86_64") == []


def test_missing_cpu_flags_of_kvm64(hook, tmp_path):
    info = tmp_path / "cpuinfo"
    info.write_text(cpu(KVM64_FLAGS))
    assert hook.missing_cpu_flags(str(info), machine=lambda: "x86_64") == \
        ["popcnt", "sse4_1", "sse4_2", "ssse3"]


def test_missing_cpu_flags_with_no_flags_line_is_every_flag(hook, tmp_path):
    info = tmp_path / "cpuinfo"
    info.write_text("processor\t: 0\n")
    assert hook.missing_cpu_flags(str(info), machine=lambda: "x86_64") == sorted(hook.X86_64_V2)


def test_missing_cpu_flags_is_empty_on_another_architecture(hook, tmp_path):
    # sharp has a prebuilt binary with no CPU level for arm64
    assert hook.missing_cpu_flags(str(tmp_path / "none"), machine=lambda: "aarch64") == []


def test_a_cpu_with_no_x86_64_v2_stops_the_hook_before_any_question(hook, paths, monkeypatch):
    (paths / "cpuinfo").write_text(cpu(KVM64_FLAGS))
    monkeypatch.setattr(hook.platform, "machine", lambda: "x86_64")

    def no_dialog():
        raise AssertionError("the hook asked a question")
    monkeypatch.setattr(hook, "load_dialog", no_dialog)
    run = Fake()
    with pytest.raises(hook.HookError) as error:
        hook.configure(VALUES, {}, run=run, chown=lambda *a: None, owner=lambda u: (1, 2),
                       interactive=True)
    message = str(error.value)
    assert "x86-64-v2" in message
    assert "popcnt sse4_1 sse4_2 ssse3" in message
    assert "x86-64-v2-AES" in message
    assert "45nodebb" in message
    # nothing is changed: no psql, no setup, no config.json
    assert run.calls == []
    assert not (paths / "nodebb" / "config.json").exists()
