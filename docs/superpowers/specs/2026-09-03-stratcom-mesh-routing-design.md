# STRATCOM Mesh Routing Design

## Goal

Allow CENTCOM to manage field nodes that cannot communicate directly with the central wireless modem by automatically relaying traffic through other STRATCOM bootstrap nodes.

## Architecture

All management traffic uses port `4510` and all operational traffic uses port `4511`. Both ports carry one wire format:

```text
STRATCOM_NET | <serialized envelope>
```

The serialized envelope is a Lua table:

```lua
{
  protocol = 2,
  id = "unique-message-id",
  source = "CENTRAL" or node id,
  destination = "CENTRAL", node id, or "*",
  ttl = 6,
  kind = "MGMT" | "BOOT_HELLO" | "BOOT_HEARTBEAT" | "MGMT_ACK" | "MGMT_ERROR" | "MGMT_DEPLOY_RESULT" | "BOOT_INFO" | "CMD" | "RUNTIME",
  payload = { ... },
}
```

Every bootstrap keeps a bounded cache of recently seen message IDs. An unseen envelope is processed locally when its destination is this node or `*`; if TTL is greater than zero it is also rebroadcast with TTL decremented. Already-seen messages are dropped. This produces controlled flooding with loop prevention and requires no static route configuration.

CENTCOM also keeps a seen-message cache and originates all commands as broadcast mesh envelopes targeted at a logical node ID. CENTCOM never depends on the destination node's modem hardware address. Responses are targeted logically at `CENTRAL` and can return through any relay.

## Discovery and claiming

Nodes periodically originate `BOOT_HEARTBEAT` envelopes addressed to `CENTRAL`, and originate `BOOT_HELLO` on startup or in response to a broadcast discovery request. Any intermediate bootstrap relays those envelopes.

CENTCOM registers the node by logical node ID and sends `MGMT/CLAIM` back to that logical ID through the mesh. A node accepts the first central claim and then accepts management/operational commands only when the logical source is `CENTRAL`.

## Deployment

Existing runtime deployment remains central-controlled. `DEPLOY_BEGIN`, `DEPLOY_CHUNK`, and `DEPLOY_COMMIT` are carried inside mesh management envelopes. Deployment chunks remain one serialized envelope argument per modem packet to stay under OpenComputers' packet-part limit.

## Runtime traffic

Runtime commands use port `4511`, `kind="CMD"`, destination equal to the node ID. Runtime responses use `kind="RUNTIME"`, destination `CENTRAL`. Relays forward these packets using the same dedupe and TTL rules.

## Safety and failure behavior

- TTL defaults to 6 hops.
- Each message ID is forwarded at most once per computer.
- Seen-message entries expire after 30 seconds and the cache is periodically pruned.
- Packets with invalid envelopes or unsupported protocol versions are ignored.
- A node never executes a management or operational command addressed to another node.
- Runtime ARM/DISARM/LAUNCH semantics are unchanged.
- Bootstrap software itself is still installed manually; normal runtime software remains centrally deployed.

## Migration

Both relay nodes and destination nodes must run bootstrap `2.1.0` or newer. CENTCOM must run central `2.1.0` or newer. Existing runtime `2.0.0` remains compatible because the bootstrap provides the same runtime context interface.
