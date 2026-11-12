"""Tests of usr/lib/keel-nodebb/serve.py: NodeBB serves on the writable
node only (handbook note 0082, section 4). The process start and the
signals of main() are integration only (CT 9385, BR1)."""
import signal
import subprocess
import types

import pytest


class Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def test_is_writable_only_out_of_recovery_and_open(serve):
    assert serve.is_writable("f", "off") is True
    assert serve.is_writable("t", "off") is False
    assert serve.is_writable("f", "on") is False


@pytest.mark.parametrize("ready,writable,serving,action", [
    (True, True, False, "start"),
    (False, True, False, None),
    (True, True, True, None),
    (True, False, True, "stop"),
    (True, False, False, None),
    (True, None, True, None),
    (True, None, False, None),
])
def test_decide(serve, ready, writable, serving, action):
    assert serve.decide(ready, writable, serving) == action


def test_psql_gives_the_output_and_the_command(serve):
    calls = []

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        return Result(0, "f|off\n")
    assert serve.psql("SELECT 1", run=run) == ("f|off", "")
    argv, kwargs = calls[0]
    assert argv[:2] == ["psql", "-X"]
    assert argv[-2:] == ["-c", "SELECT 1"]
    assert "-d" in argv and argv[argv.index("-d") + 1] == "nodebb"
    assert kwargs["timeout"] == serve.QUERY_TIMEOUT


def test_psql_failure_gives_none_and_the_error(serve):
    assert serve.psql("x", run=lambda *a, **k: Result(2, "", "no socket\n")) == (None, "no socket")
    assert serve.psql("x", run=lambda *a, **k: Result(2, "", "")) == (None, "psql exit 2")


def test_psql_timeout_or_missing_tool_gives_none(serve):
    def timeout(*a, **k):
        raise subprocess.TimeoutExpired("psql", 5)

    def missing(*a, **k):
        raise FileNotFoundError(2, "No such file")
    out, error = serve.psql("x", run=timeout)
    assert out is None and "timed out" in error
    out, error = serve.psql("x", run=missing)
    assert out is None and error


def test_psql_error_with_no_text_names_its_type(serve):
    def bare(*a, **k):
        raise OSError()
    assert serve.psql("x", run=bare) == (None, "OSError")


def test_poller_reads_the_role(serve):
    assert serve.Poller(lambda sql: ("f|off", "")).writable() is True
    assert serve.Poller(lambda sql: ("t|on", "")).writable() is False


def test_poller_says_a_problem_once(serve, capsys):
    answers = iter([(None, "down"), (None, "down"), ("f|off", ""), (None, "down")])
    poller = serve.Poller(lambda sql: next(answers))
    assert poller.writable() is None
    assert poller.writable() is None
    assert poller.writable() is True
    assert poller.writable() is None
    assert capsys.readouterr().err.count("PostgreSQL gave no answer: down") == 2


def test_poller_refuses_an_answer_of_another_shape(serve, capsys):
    assert serve.Poller(lambda sql: ("f", "")).writable() is None
    assert "not two fields" in capsys.readouterr().err


def test_mark_replica(serve, tmp_path, capsys):
    mark = tmp_path / "replica"
    serve.mark_replica(False, str(mark))
    assert mark.exists()
    serve.mark_replica(None, str(mark))
    assert mark.exists()
    serve.mark_replica(True, str(mark))
    assert not mark.exists()
    serve.mark_replica(True, str(mark))
    serve.mark_replica(False, str(tmp_path / "no" / "dir"))
    assert "did not change" in capsys.readouterr().err


def test_ready_and_stamp(serve, tmp_path):
    assert serve.is_ready(str(tmp_path / "ready")) is False
    (tmp_path / "ready").write_text("")
    assert serve.is_ready(str(tmp_path / "ready")) is True
    stamp = tmp_path / "stamp"
    assert serve.read_stamp(str(stamp)) is None
    serve.write_stamp("a b", str(stamp))
    assert serve.read_stamp(str(stamp)) == "a b"


class Steps:
    """A fake of subprocess.run for prepare(): each command gives a code."""

    def __init__(self, codes=None, raises=None):
        self.codes = codes or {}
        self.raises = raises or {}
        self.calls = []

    def __call__(self, argv, **kwargs):
        name = argv[2] if argv[1] == "-y" else argv[1]
        self.calls.append(name)
        assert kwargs["cwd"] == "/var/www/nodebb"
        if name in self.raises:
            raise self.raises[name]
        return Result(self.codes.get(name, 0))


def answers(active, secret=("s3cret", "")):
    """A fake of psql: the active set, and the secret of the row."""
    return lambda sql: secret if sql == "SELECT secret FROM keel_nodebb_secret WHERE id = 1" else (active, "")


def test_prepare_with_the_same_set_does_not_build_and_gives_the_secret(serve):
    run = Steps()
    assert serve.prepare(query=answers("p1 theme:t"), run=run, stamp=lambda: "p1 theme:t",
                         set_stamp=pytest.fail) == "s3cret"
    assert run.calls == ["upgrade"]


def test_prepare_with_another_set_builds_and_writes_the_stamp(serve):
    run, written = Steps(), []
    assert serve.prepare(query=answers("p1 p2"), run=run, stamp=lambda: "p1",
                         set_stamp=written.append) == "s3cret"
    assert run.calls == ["upgrade", "build"]
    assert written == ["p1 p2"]


def test_prepare_with_no_secret_row_does_not_start(serve, capsys):
    q = answers("p1", secret=(None, 'relation "keel_nodebb_secret" does not exist'))
    assert serve.prepare(query=q, run=Steps(), stamp=lambda: "p1") is None
    assert "session secret is not known" in capsys.readouterr().err
    assert serve.prepare(query=answers("p1", secret=("", "")), run=Steps(), stamp=lambda: "p1") is None
    err = capsys.readouterr().err
    assert "holds no secret" in err
    assert "s3cret" not in err


def test_prepare_stops_when_the_upgrade_fails(serve, capsys):
    assert serve.prepare(query=pytest.fail, run=Steps({"upgrade": 1})) is None
    assert "schema upgrade failed with exit 1" in capsys.readouterr().err
    run = Steps(raises={"upgrade": FileNotFoundError("node")})
    assert serve.prepare(query=pytest.fail, run=run) is None
    assert "did not run" in capsys.readouterr().err


def test_prepare_stops_when_the_active_set_is_not_known(serve, capsys):
    assert serve.prepare(query=lambda sql: (None, "down"), run=Steps()) is None
    assert "active plugins are not known" in capsys.readouterr().err


def test_prepare_stops_when_the_build_fails(serve, capsys):
    q = answers("p2")
    assert serve.prepare(query=q, run=Steps({"build": 2}), stamp=lambda: "p1") is None
    assert "build failed with exit 2" in capsys.readouterr().err
    run = Steps(raises={"build": subprocess.TimeoutExpired("build", 1)})
    assert serve.prepare(query=q, run=run, stamp=lambda: "p1") is None
    assert "build did not run" in capsys.readouterr().err


def test_prepare_starts_when_the_stamp_cannot_be_written(serve, capsys):
    def no_stamp(value):
        raise PermissionError("read-only")
    assert serve.prepare(query=answers("p2"), run=Steps(), stamp=lambda: None,
                         set_stamp=no_stamp) == "s3cret"
    assert "stamp was not written" in capsys.readouterr().err


class World:
    """The fakes of a Supervisor: a role that the test sets, a clock, a
    child that lives until the test ends it."""

    def __init__(self, serve, prepared="s3cret"):
        self.writable = True
        self.ready = True
        self.prepared = prepared
        self.now = 100.0
        self.alive = set()
        self.started = []
        self.stopped = []
        self.marks = []
        poller = types.SimpleNamespace(writable=lambda: self.writable)
        self.secrets = []
        self.sup = serve.Supervisor(poller, lambda: self.ready, lambda: self.prepared, self.start,
                                    self.stop, lambda c: c in self.alive, lambda: self.now,
                                    self.marks.append)

    def start(self, secret):
        self.secrets.append(secret)
        child = len(self.started) + 1
        self.started.append(child)
        self.alive.add(child)
        return child

    def stop(self, child):
        self.stopped.append(child)
        self.alive.discard(child)


def test_supervisor_starts_on_a_writable_node(serve):
    w = World(serve)
    w.sup.tick()
    assert w.started == [1]
    assert w.secrets == ["s3cret"]
    assert w.marks == [True]
    w.sup.tick()
    assert w.started == [1]
    assert w.marks == [True]


def test_supervisor_waits_for_the_ready_mark(serve):
    w = World(serve)
    w.ready = False
    w.sup.tick()
    assert w.started == []
    w.ready = True
    w.sup.tick()
    assert w.started == [1]


def test_supervisor_stops_on_a_standby_and_marks_it(serve):
    w = World(serve)
    w.sup.tick()
    w.writable = False
    w.sup.tick()
    assert w.stopped == [1]
    assert w.marks == [True, False]
    w.sup.stop_all("again")
    assert w.stopped == [1]


def test_supervisor_changes_nothing_when_the_server_is_silent(serve):
    w = World(serve)
    w.sup.tick()
    w.writable = None
    w.sup.tick()
    assert w.stopped == []
    assert w.marks == [True]


def test_supervisor_restarts_an_ended_server_after_the_delay(serve, capsys):
    w = World(serve)
    w.sup.tick()
    w.alive.discard(1)
    w.sup.tick()
    # the group of the ended loader is stopped first (an orphan worker)
    assert w.stopped == [1]
    assert w.started == [1]
    w.now += serve.RESTART_DELAY
    w.sup.tick()
    assert w.started == [1, 2]
    assert "the server ended" in capsys.readouterr().err


def test_supervisor_waits_after_a_failed_preparation(serve):
    w = World(serve, prepared=None)
    w.sup.tick()
    assert w.started == []
    w.prepared = "s3cret"
    w.sup.tick()
    assert w.started == []
    w.now += serve.RESTART_DELAY
    w.sup.tick()
    assert w.started == [1]


def test_supervisor_without_a_mark_function(serve):
    sup = serve.Supervisor(types.SimpleNamespace(writable=lambda: False), lambda: True, lambda: True,
                           pytest.fail, pytest.fail, lambda c: True, lambda: 0.0)
    sup.tick()
    assert sup.marked is False


class Child:
    def __init__(self, ends_after=None):
        self.pid = 4242
        self.ends_after = ends_after
        self.polls = 0
        self.waited = False

    def poll(self):
        self.polls += 1
        if self.ends_after is not None and self.polls >= self.ends_after:
            return 0
        return None

    def wait(self):
        self.waited = True


def test_stop_child_sends_term_to_the_group(serve):
    sent = []
    child = Child(ends_after=2)
    serve.stop_child(child, clock=iter([0, 0, 0]).__next__, sleep=lambda s: None,
                     killpg=lambda pid, sig: sent.append((pid, sig)))
    assert sent == [(4242, signal.SIGTERM)]


def test_stop_child_kills_a_group_that_does_not_end(serve):
    sent = []
    clock = iter([0, 1, serve.STOP_WAIT_SECONDS + 1]).__next__
    child = Child()
    serve.stop_child(child, clock=clock, sleep=lambda s: None, killpg=lambda pid, sig: sent.append(sig))
    assert sent == [signal.SIGTERM, signal.SIGKILL]
    assert child.waited


def test_stop_child_of_a_group_that_is_gone(serve):
    def gone(pid, sig):
        raise ProcessLookupError()
    child = Child()
    serve.stop_child(child, killpg=gone)
    assert child.waited
    sent = []

    def gone_at_kill(pid, sig):
        sent.append(sig)
        if sig == signal.SIGKILL:
            raise ProcessLookupError()
    child = Child()
    serve.stop_child(child, clock=iter([0, serve.STOP_WAIT_SECONDS + 1]).__next__, sleep=lambda s: None,
                     killpg=gone_at_kill)
    assert sent == [signal.SIGTERM, signal.SIGKILL]
    assert child.waited


def test_child_alive_and_start_child(serve):
    assert serve.child_alive(Child()) is True
    assert serve.child_alive(Child(ends_after=1)) is False
    calls = []
    serve.start_child("s3cret", popen=lambda argv, **kwargs: calls.append((argv, kwargs)),
                      environ={"PATH": "/usr/bin", "HOME": "/var/lib/nodebb"})
    argv, kwargs = calls[0]
    assert argv == ["/usr/bin/node", "loader.js", "--no-daemon", "--no-silent"]
    assert "s3cret" not in " ".join(argv)
    assert kwargs["cwd"] == "/var/www/nodebb" and kwargs["start_new_session"] is True
    # NodeBB reads `secret` from the environment before config.json
    assert kwargs["env"] == {"PATH": "/usr/bin", "HOME": "/var/lib/nodebb", "secret": "s3cret"}
