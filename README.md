<p align="center">
  <img src="docs/images/blip.svg" width="140" height="140" alt="Blip, Photon's assistant: an amber dot with two eyes, thinking, working and finishing a task">
</p>

# Photon

Photon is a self-hosted home for AI agents that do real work on your own
computers. You run one small server, the **hub**, put a **node** on each
machine you want it to use (laptop, desktop, Mac mini, a VM), and work with
it from the browser. It runs on your ChatGPT plan.

There are two ways to work with it:

- **Projects and threads.** A project is any body of work, not just code:
  its purpose, notes the agents read and write, and threads. Each thread is
  an agent conversation that can run commands and look at screenshots on
  any of your machines, and search the web. Run a build on the Mac, check a
  log on the server and write down what it found, all in one thread.
- **Blip**, your assistant. Blip handles everyday requests itself, starts
  and follows threads in every project, answers their questions when it
  knows what you'd say (and asks you when it doesn't), remembers what you
  tell it, runs things on a schedule, and tells you when work finishes or
  needs you. Turn on ambient mode and it sends a digest of what changed
  every few hours and points out threads left alone.

## Why you might want it

- **Your machines, one conversation.** Nodes connect out to the hub, so
  machines behind NAT or on different networks all work. No ports to open
  on them.
- **Work doesn't get lost.** Every turn, command and schedule is saved before
  it's shown. Close the tab or restart the hub, and the work picks up where
  it stopped. A command keeps running while its machine is cut off from the
  hub, and reports back when it reconnects.
- **Skills, written once.** Write or install instructions ("how we deploy",
  "running iOS simulators") and turn each on for Blip, for a project, or for
  a machine, so any agent working on that machine gets it.
- **Private.** One hub, one person. Put it on your Tailscale network and
  only your own devices can open it. The ChatGPT sign-in stays on the hub;
  nodes never hold it.

## Is it for you?

Photon is early and built for one person running their own hub. It's a good
fit if you have a few computers you'd like an agent to use, a ChatGPT plan,
and you're happy running a small server. It's written in Elixir, if you want
to change it.

> [!WARNING]
> Nodes run the agents' commands **without a sandbox**, as the node's user.
> Install nodes only on machines, VMs or containers you're happy for an agent
> to use.

## Try it on your computer

Needs Elixir 1.20+ and Erlang/OTP 28+.

```sh
git clone https://github.com/h14h/photon && cd photon/apps/hub
mix setup
mix phx.server
```

Open http://localhost:4000. The hub runs a node for your own computer,
called `local`, so there's a machine to use straight away.

1. **Sign in with ChatGPT** in Settings: choose **Sign in with ChatGPT**,
   then **Open ChatGPT**, and approve Photon. ChatGPT then sends you to a
   `http://127.0.0.1:…/auth/callback` page that won't load. That's expected:
   copy its whole address and paste it into Settings.
2. **Talk to Blip** with the button in the bottom-right corner. Try
   `on local, what's using the most disk?`
3. **Start a project** with the **+** next to Projects in the sidebar, give
   it a purpose, then choose **New thread** on its page.

To look around without signing in, run `PHOTON_MOCK_MODEL=1 mix phx.server`.
Blip then follows a fixed script; type `help` to see what it understands.

## Run your own hub

The hub deploys to [Fly.io](https://fly.io) with no Elixir needed:

```sh
git clone https://github.com/h14h/photon && cd photon
fly launch --copy-config
```

You get one always-on machine with a volume for your data. The first build
takes several minutes. Sign in with any username and the generated
password (`fly ssh console -C "cat /data/password"`).

If you use [Tailscale](https://tailscale.com), give the hub an
[auth key](https://login.tailscale.com/admin/settings/keys):
`fly secrets set TS_AUTHKEY=tskey-auth-... PHOTON_SSH_USER=<you>`. It then
lists your machines for one-click installs, and your own devices skip the
password. You can also keep the hub off the internet entirely, so only your
devices can reach it. [ARCHITECTURE.md](ARCHITECTURE.md#running-a-hub)
shows how, along with running the hub under Docker and every setting.

### Add your machines

Open **Nodes** in the hub:

- **On your tailnet**, click **Install** next to a machine. The hub logs in
  over SSH, installs the node as a user service, and waits for it to connect.
- **Anywhere else**, name the machine and run the one-line command the page
  gives you on it.

Nodes need no root and nothing else installed. A machine that runs a node
can't open the hub itself, so a command an agent runs there can't act as
you. Use another device to open the hub.

## Working on Photon

```sh
(cd apps/hub && mix test)
(cd apps/hub && mix precommit)   # every check: compiler and types, format, Credo, tests
```

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the hub, nodes and agents
work and how the code is laid out. [AGENTS.md](AGENTS.md) lists the checks
each change must pass.
