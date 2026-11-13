NodeBB - Forum for a project
============================

`NodeBB`_ is a forum platform built on Node.js. This layer serves it behind
Nginx on the LNPP stack of Keel (handbook note 0082):

::

    core  ->  web  ->  lnpp  ->  nodebb

What the layer adds
-------------------

- NodeBB 4.16.7 in ``/var/www/nodebb``, from the release tarball at a
  pinned sha256, owned by root. The dependencies come from the reviewed
  lock file ``usr/share/keel-nodebb/package-lock.json`` with ``npm ci``.
- Node.js 24 from the Keel package ``keel-nodejs-24`` (note 0083). Each
  Node.js line is its own package, and the lines conflict. The layer names
  its line in ``plan/main``.
- An apt pin (``/etc/apt/preferences.d/keel-nodebb-nodejs``) keeps line
  24 and refuses the other lines.
- ``nodebb-nodejs.path`` restarts NodeBB when ``/usr/lib/keel-nodejs/bin/node``
  changes. The Node.js package has no maintainer script, so without this
  unit NodeBB keeps the old binary after an upgrade.
- The session secret is in the one-row table ``keel_nodebb_secret`` of the
  database, so a pair shares it with the session rows. The first writable
  boot writes it (``secrets.nodebb_secret`` of the spec, which keel renders
  as ``KEEL_SECRET_NODEBB_SECRET``, else a new value), and no later boot
  changes it. ``serve.py`` gives it to NodeBB in the environment.
- PostgreSQL of lnpp in every mode: embedded in ``simple``, the pair of
  decision 0054 in the cloud modes. No Redis.
- ``nodebb.service`` runs ``usr/lib/keel-nodebb/serve.py`` as the user
  nodebb. It starts NodeBB only while PostgreSQL accepts writes, runs the
  schema upgrade before a start, and builds the assets again when the
  active plugins change. On a standby it writes ``/run/keel-nodebb/replica``,
  and Nginx shows the replica notice.
- The routes in ``/etc/nginx/keel-default.d/60-keel-nodebb.conf`` and
  ``keel-front.d``: NodeBB on ``127.0.0.1:4567``, socket.io with the
  Upgrade headers, a larger body on the upload routes only.
- The first boot hook ``45nodebb`` and ``bin/nodebb.py``: ``config.json``,
  the role and database ``nodebb``, and ``./nodebb setup`` with the admin
  of the spec (``secrets.app_password``, ``app.options.admin_user``). With
  no ``secrets.app_password``, keel-init asks it on the console (the screen
  "NodeBB password").
- NodeBB logs in to PostgreSQL on the socket ``/run/postgresql`` with the
  peer authentication of the user nodebb. The role ``nodebb`` has no
  password, and ``config.json`` holds no database password.
  ``secrets.db_password`` is the password of the account ``postgres``
  only.
- NodeBB writes ``build/``, ``logs/``, the pidfile, the emoji data of
  nodebb-plugin-emoji, and ``/var/lib/nodebb/uploads``, which a pair
  replicates (``state.replicate`` of ``nodebb.yaml``).
- The check page of lnpp is removed.

The CPU of a VM
---------------

NodeBB needs a CPU of the x86-64-v2 level. Its image library, sharp, loads
its binary only on that level, and its WebAssembly build needs SSE4.1 too.
An LXC uses the CPU of the host. A VM uses the CPU type of its
configuration: the Proxmox VE web interface gives ``x86-64-v2-AES``, which
is correct, but ``qm create`` with no ``--cpu`` gives ``kvm64``, which is
not. On such a CPU the first boot hook ``45nodebb`` stops and says what to
do:

1. Stop the VM.
2. Set its CPU type to ``x86-64-v2-AES`` or ``host`` (Hardware, Processors,
   Type; or ``qm set VMID --cpu x86-64-v2-AES``).
3. Start the VM and run ``/usr/lib/inithooks/firstboot.d/45nodebb`` as
   root on its console.

A change of the Node.js line
----------------------------

Each Node.js line is its own package, and the lines conflict (handbook
note 0083). ``/etc/apt/preferences.d/keel-nodebb-nodejs`` keeps line 24
and refuses every other line, so ``apt install keel-nodejs-26`` finds no
candidate and cannot remove line 24 by surprise. Updates of line 24 come
with ``apt upgrade`` as usual.

The normal change of line is a new image: the plan names the new line,
the pin follows it, and the image passes commissioning on both sites
first. To change the line of an installed node on purpose:

1. Make sure that NodeBB of this layer passed commissioning on the new
   line. A native module of NodeBB is built for the ABI of one line.
2. Edit ``/etc/apt/preferences.d/keel-nodebb-nodejs``: put the new line,
   for example ``keel-nodejs-26`` and ``Pin: version 26.*``, in the first
   record.
3. Run ``apt install keel-nodejs-26``. apt removes ``keel-nodejs-24``.
4. ``nodebb-nodejs.path`` restarts NodeBB on the new binary. Check the
   forum.

To go back, do the same steps with line 24.

Build
-----

The build needs ``keel-nodejs-24`` in the Keel archive that the build reads:

::

    bt-layer nodebb --parent lnpp

Open items
----------

- A login that survives a promote is not tested: no pair test ran. keel
  has no general path that gives one generated value to both nodes of a
  pair; this layer keeps its secret in the database instead.
- Coraza exclusions for posts are not written and not tested.
- The option ``trusted_proxy`` of the old layer is gone.
- No nodebb layer is published, so the `appliance` check fails until a
  layer on lnpp is published after commissioning.

Tests
-----

See ``COVERAGE.md`` and ``tests/README.md``.

.. _NodeBB: https://nodebb.org
