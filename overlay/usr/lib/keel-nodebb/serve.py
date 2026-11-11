#!/usr/bin/python3
"""NodeBB serves on the writable node only (handbook note 0082, section 4).

NodeBB writes to its database at start (the session table, the schema), so
it cannot start against a PostgreSQL server in recovery. This process is
nodebb.service. It runs on every node as the user nodebb:

- every POLL_SECONDS it asks PostgreSQL one read-only question on the unix
  socket: is the server out of recovery, and open for writes? A standby
  can answer. PostgreSQL authenticates the user nodebb by peer;
- when the answer is yes and the first boot hook has finished (the file
  READY), it prepares NodeBB and starts it as a child:
  1. `./nodebb -y upgrade -s` runs the schema steps of a new code version.
     It writes the database, so it runs on the writable node only;
  2. when the active plugins and the theme differ from the set of the last
     build on this node (BUILD_STAMP), `./nodebb build` builds the assets
     again. An admin who activates a bundled plugin writes the database,
     and the build of each node must follow;
  3. `node loader.js --no-daemon --no-silent` starts the server;
- when the answer is no, it stops the child at once. A fenced or old
  primary is in recovery, so it never serves;
- when the server does not answer, it changes nothing, so a restart of
  PostgreSQL does not take NodeBB down;
- it writes the mark REPLICA_MARK while the node is a standby and removes
  it on a writable node. Nginx reads the mark and shows a page that says
  why NodeBB does not serve here (etc/nginx/keel-default.d/60-keel-nodebb.conf).

The first boot hook writes READY at its end, so a failed hook leaves NodeBB
off. The steps of the preparation block the poll while they run.
"""
import os
import signal
import subprocess
import sys
import time

NODEBB_DIR = "/var/www/nodebb"
READY = "/var/lib/keel-nodebb/ready"
# in RuntimeDirectory=keel-nodebb of nodebb.service, so it goes when the unit stops
REPLICA_MARK = "/run/keel-nodebb/replica"
BUILD_STAMP = NODEBB_DIR + "/build/keel-active-set"
DATABASE = "nodebb"
POLL_SECONDS = 1.0
QUERY_TIMEOUT = 5
PREPARE_TIMEOUT = 1800
RESTART_DELAY = 5.0
STOP_WAIT_SECONDS = 30.0
STOP_WAIT_STEP = 0.1
QUESTION = "SELECT pg_is_in_recovery(), current_setting('transaction_read_only')"
# The active plugins (a sorted set) and the theme (a field of the hash
# config) in the PostgreSQL schema of NodeBB 4
ACTIVE_SET = (
    "SELECT coalesce(string_agg(v, ' ' ORDER BY v), '') FROM ("
    "SELECT z.value AS v FROM legacy_zset z JOIN legacy_object o"
    " ON o._key = z._key AND o.type = z.type"
    " WHERE z._key = 'plugins:active' AND (o.\"expireAt\" IS NULL OR o.\"expireAt\" > now())"
    " UNION ALL SELECT 'theme:' || (h.data->>'theme:id') FROM legacy_hash h"
    " WHERE h._key = 'config' AND h.data ? 'theme:id') s")
NODE = "/usr/bin/node"
UPGRADE = ["./nodebb", "-y", "upgrade", "-s"]
BUILD = ["./nodebb", "build"]
SERVER = [NODE, "loader.js", "--no-daemon", "--no-silent"]


def say(level, message):
    """A line for the journal. <4> is the syslog level warning, <5> notice."""
    print("<%d>keel-nodebb: %s" % (level, message), file=sys.stderr, flush=True)


def is_writable(in_recovery, read_only):
    """True when the server is out of recovery and is open for writes."""
    return in_recovery == "f" and read_only == "off"


def decide(ready, writable, serving):
    """The action for the state: "start", "stop" or None."""
    if writable is False and serving:
        return "stop"
    if writable is True and not serving and ready:
        return "start"
    return None


def psql(sql, run=subprocess.run):
    """The output of one statement, or None when the server gives no answer."""
    try:
        result = run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", DATABASE, "-c", sql],
                     capture_output=True, text=True, timeout=QUERY_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error) or type(error).__name__
    if result.returncode != 0:
        return None, (result.stderr.strip() or "psql exit %d" % result.returncode)
    return result.stdout.strip(), ""


class Poller:
    """The role of PostgreSQL. A problem is said once, not at every poll."""

    def __init__(self, query=psql):
        self.query = query
        self.last_error = ""

    def writable(self):
        out, error = self.query(QUESTION)
        if out is None:
            if error != self.last_error:
                say(4, "PostgreSQL gave no answer: %s" % error)
            self.last_error = error
            return None
        self.last_error = ""
        fields = out.split("|")
        if len(fields) != 2:
            say(4, "PostgreSQL gave an answer that is not two fields: %r" % out)
            return None
        return is_writable(*fields)


def mark_replica(writable, path=REPLICA_MARK):
    """Write the mark on a standby (False), remove it on a writable node
    (True), change nothing when the server is silent (None)."""
    try:
        if writable is False:
            with open(path, "w"):
                pass
        elif writable is True and os.path.exists(path):
            os.remove(path)
    except OSError as error:
        say(4, "the replica mark %s did not change: %s" % (path, error))


def is_ready(path=READY):
    return os.path.exists(path)


def read_stamp(path=BUILD_STAMP):
    try:
        with open(path) as stamp:
            return stamp.read().strip()
    except OSError:
        return None


def write_stamp(value, path=BUILD_STAMP):
    with open(path, "w") as stamp:
        stamp.write(value + "\n")


def prepare(query=psql, run=subprocess.run, stamp=read_stamp, set_stamp=write_stamp):
    """The steps before a start, on the writable node. True when NodeBB can
    start: the schema is current and the build fits the active set."""
    try:
        upgrade = run(UPGRADE, cwd=NODEBB_DIR, timeout=PREPARE_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        say(4, "the schema upgrade did not run: %s" % error)
        return False
    if upgrade.returncode != 0:
        say(4, "the schema upgrade failed with exit %d" % upgrade.returncode)
        return False
    active, error = query(ACTIVE_SET)
    if active is None:
        say(4, "the active plugins are not known: %s" % error)
        return False
    if stamp() == active:
        return True
    say(5, "the active plugins and theme changed, so the assets are built again")
    try:
        build = run(BUILD, cwd=NODEBB_DIR, timeout=PREPARE_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        say(4, "the build did not run: %s" % error)
        return False
    if build.returncode != 0:
        say(4, "the build failed with exit %d" % build.returncode)
        return False
    try:
        set_stamp(active)
    except OSError as error:
        say(4, "the build stamp was not written: %s" % error)
    return True


class Supervisor:
    def __init__(self, poller, is_ready, prepare, start_child, stop_child, child_alive, clock,
                 mark=None):
        self.poller = poller
        self.is_ready = is_ready
        self.prepare = prepare
        self.start_child = start_child
        self.stop_child = stop_child
        self.child_alive = child_alive
        self.clock = clock
        self.mark = mark
        self.marked = None
        self.child = None
        self.not_before = 0.0

    def tick(self):
        if self.child is not None and not self.child_alive(self.child):
            say(4, "the server ended")
            self.child = None
            self.not_before = self.clock() + RESTART_DELAY
        writable = self.poller.writable()
        if writable is not None and writable != self.marked:
            self.marked = writable
            if self.mark is not None:
                self.mark(writable)
        action = decide(self.is_ready(), writable, self.child is not None)
        if action == "start" and self.clock() >= self.not_before:
            if not self.prepare():
                self.not_before = self.clock() + RESTART_DELAY
                return
            self.child = self.start_child()
            say(5, "serving")
        elif action == "stop":
            self.stop_all()

    def stop_all(self):
        if self.child is None:
            return
        self.stop_child(self.child)
        self.child = None
        say(5, "stopped, the node is not writable")


def stop_child(child, clock=time.monotonic, sleep=time.sleep, killpg=os.killpg):
    """SIGTERM to the group of the child (loader.js and its workers), then
    SIGKILL after STOP_WAIT_SECONDS."""
    try:
        killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        child.wait()
        return
    end = clock() + STOP_WAIT_SECONDS
    while clock() < end:
        if child.poll() is not None:
            return
        sleep(STOP_WAIT_STEP)
    try:
        killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()


def child_alive(child):
    return child.poll() is None


def start_child(popen=subprocess.Popen):
    """loader.js in a new session, so a stop reaches every worker."""
    return popen(SERVER, cwd=NODEBB_DIR, start_new_session=True)


def main():  # pragma: no cover
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(True))
    supervisor = Supervisor(Poller(), is_ready, prepare, start_child, stop_child, child_alive,
                            time.monotonic, mark_replica)
    say(5, "waiting for a writable PostgreSQL")
    while not stopping:
        supervisor.tick()
        time.sleep(POLL_SECONDS)
    supervisor.stop_all()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
