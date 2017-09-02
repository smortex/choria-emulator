# What?

This is a tool that creates multiple Choria instances in memory in a single process.

Each instance can have a number of emulated agents, belong to many sub collectives and generally you'll be able to interact with them from the normal Choria `mco` CLI.  Each instance will make a NATS connection just like Choria does and make the same subscriptions. 

On my MBP I can run 2 000 instances of Choria along with a Choria Broker and the Choria client all on the same laptop and response times are around 1.5 seconds for all nodes.

The idea is that you will use many VMs, say a few 100, deploy standard Choria to them along with an agent that will be provided here to manage a big network of emulated Choria instances.

Each of these 100s of VMs can run lets say a thousand Choria instances at a time and you can point them at different topologies of NATS, Federation etc and do tests with different concurrencies and payload sizes.

```
usage: choria-emulator --name=NAME --instances=INSTANCES --agents=AGENTS [<flags>]

Emulator for Choria Networks

Flags:
      --help                 Show context-sensitive help (also try --help-long and --help-man).
      --version              Show application version.
      --name=NAME            Instance name
  -i, --instances=INSTANCES  Number of instances to start
  -a, --agents=1             Number of emulated agents to start
      --collectives=1        Number of emulated subcollectives to create
  -c, --config=CONFIG        Choria configuration file
      --tls                  Enable TLS on the NATS connections
      --verify               Enable TLS certificate verifications on the NATS connections
      --server=SERVER ...    NATS Server pool, specify multiple times (eg one:4222)
```

## Agents
When you specify the creation of 10 agents you will get a series of agents called `emulated0`, `emulated1` and so forth.

These agents are all identical and have just one action `generate` that takes a `size` argument. It will create a reply message with a string reply equal in size to what was requested.

This is good test the impact of varying sizes of payload on your infrastructure.

Additionally it has the standard `discovery` agent so `mco ping` and so forth works.  Filters wise it only support the `agent` filter which is sufficient for this kind of testing.

```
$ mco rpc emulated0 generate size=100 -I test-1 -j
[
  {
    "agent": "emulated0",
    "action": "generate",
    "sender": "test-1",
    "statuscode": 0,
    "statusmsg": "OK",
    "data": {
      "message": "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
    }
  }
]
```

## Subcollectives
Subcollectives are supported, by default it belongs to the typical `mcollective` sub collective.

If you ask if to belong to more than 3 using the `--collectives` option it will subscribe to collectives `mcollective`, `collective1` and `collective2`.