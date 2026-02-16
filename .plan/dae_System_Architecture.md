## System Architecture

Relevant source files

-   [README.md](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md)
-   [control/control\_plane.go](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go)
-   [control/control\_plane\_core.go](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go)
-   [control/kern/tproxy.c](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c)

This document provides a comprehensive overview of dae's system architecture, including its component relationships, traffic flow, and integration between user space and kernel space via eBPF technology. For specific configuration details, see [Configuration Reference](https://deepwiki.com/daeuniverse/dae/3-configuration-reference). For protocol-specific implementations, see [Protocol Support](https://deepwiki.com/daeuniverse/dae/5.3-protocol-support).

## Overview

dae is a high-performance transparent proxy solution that leverages eBPF programs running in the Linux kernel to intercept and route network traffic with minimal performance overhead. The architecture consists of a user-space control plane written in Go and kernel-space eBPF programs that handle packet processing and traffic interception.

```text
Network InterfacesKernel Space (eBPF)User SpaceControlPlane
Main OrchestratorDnsController
DNS Resolution & RoutingRoutingMatcher
Traffic Routing LogicOutbound DialerGroups
Proxy ManagementConfiguration System
Rules & Settingstproxy_lan_ingresstproxy_lan_egresstproxy_wan_ingresstproxy_wan_egresstproxy_dae0_ingresstproxy_dae0peer_ingresseBPF Maps
routing_tuples_map
domain_routing_map
outbound_connectivity_mapLAN Interfaces
docker0, auto-detectWAN Interfaces
eth0, auto-detectVirtual Interfaces
dae0/dae0peer
```

Sources: [control/control\_plane.go48-80](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L48-L80) [control/kern/tproxy.c1066-1747](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c#L1066-L1747)

## Core Components

### ControlPlane

The `ControlPlane` is the central orchestrator that manages all system components and coordinates between user space and kernel space operations.

```text
Core ResponsibilitiesControlPlane StructurecontrolPlaneCore
Kernel IntegrationdnsController
DNS ManagementroutingMatcher
Rule Processingoutbounds
[]DialerGrouprealDomainSet
Bloom FilterApplication Lifecycle
Start/Stop/ReloadTraffic Handling
TCP/UDP ProcessingConnection Management
inConnections sync.MapNetwork Readiness
onceNetworkReady
```

Sources: [control/control\_plane.go48-80](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L48-L80) [control/control\_plane.go82-509](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L82-L509)

### controlPlaneCore

The `controlPlaneCore` manages the low-level eBPF integration and network interface binding.

```text
Network BindingcontrolPlaneCorebpfObjects
eBPF Programs & MapsInterfaceManager
Network Interface HandlingdeferFuncs
[]func() errorflip
Program VersioningbindLan()
LAN Interface BindingbindWan()
WAN Interface BindingbindDaens()
Virtual Interface SetupsetupSkPidMonitor()
Process Tracking
```

Sources: [control/control\_plane\_core.go34-51](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go#L34-L51) [control/control\_plane\_core.go200-333](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go#L200-L333)

## eBPF Program Architecture

### Traffic Interception Programs

dae uses multiple eBPF programs attached to different network interfaces and directions to intercept traffic:

| Program | Interface | Direction | Purpose |
| --- | --- | --- | --- |
| `tproxy_lan_ingress` | LAN | Ingress | Intercept traffic from LAN clients |
| `tproxy_lan_egress` | LAN | Egress | Update UDP connection state |
| `tproxy_wan_ingress` | WAN | Ingress | Track WAN incoming traffic |
| `tproxy_wan_egress` | WAN | Egress | Route outgoing localhost traffic |
| `tproxy_dae0_ingress` | dae0 | Ingress | Handle return traffic from control plane |
| `tproxy_dae0peer_ingress` | dae0peer | Ingress | Assign traffic to control plane listener |

```text
Control PlaneeBPF Interception PointsTraffic FlowLAN ClientLocalhost ProcessInternettproxy_lan_ingress
New connectionstproxy_lan_egress
UDP state trackingtproxy_wan_ingress
Inbound traffictproxy_wan_egress
Outbound routingControl Plane
TCP/UDP Listeners
```

Sources: [control/kern/tproxy.c1066-1747](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c#L1066-L1747)

### eBPF Maps

The eBPF programs use several maps to store routing decisions and connection state:

```text
Map UsageeBPF Mapsrouting_tuples_map
Connection Routing Cachedomain_routing_map
IP to Domain Mappingoutbound_connectivity_map
Outbound Health Statuscookie_pid_map
Process Identificationudp_conn_state_map
UDP Connection Trackingroute()
Routing DecisionsDomain-based RoutingOutbound Health ChecksProcess Name RoutingUDP State Management
```

Sources: [control/kern/tproxy.c184-379](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c#L184-L379)

## Traffic Processing Flow

### Packet Classification and Routing

When a packet is intercepted by an eBPF program, it goes through the `route()` function to determine its destination:

```text
Incoming Packetparse_transport()
Extract Headersget_tuples()
5-tuple Extractionroute()
Main Routing Logicroute_loop_cb()
Rule IterationMatch Types
MatchType_DomainSet
MatchType_IpSet
MatchType_Port
MatchType_ProcessNameRouting Decisions
OUTBOUND_DIRECT
OUTBOUND_BLOCK
OUTBOUND_CONTROL_PLANE_ROUTING
```

Sources: [control/kern/tproxy.c872-935](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c#L872-L935) [control/kern/tproxy.c634-870](https://github.com/daeuniverse/dae/blob/3a846ff2/control/kern/tproxy.c#L634-L870)

### Connection Handling

For traffic that needs to be proxied, the control plane handles the actual connection establishment and data forwarding:

```text
"Proxy Server""Control Plane""eBPF Program"Client"Proxy Server""Control Plane""eBPF Program"ClientNew Connectionroute() DecisionRedirect to dae0chooseBestDnsDialer()ChooseDialTarget()Establish ConnectionConnection EstablishedProxy Connection
```

Sources: [control/control\_plane.go635-711](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L635-L711) [control/control\_plane.go883-983](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L883-L983)

## DNS Resolution Architecture

### DNS Controller Integration

The `DnsController` manages DNS resolution and domain-based routing by maintaining a cache of DNS responses and updating eBPF maps with domain routing information:

```text
DNS UpstreamsDomain RoutingDNS Resolution FlowDNS RequestDnsController.Handle_()RequestMatcher
Route to UpstreamResponseMatcher
Accept/Reject ResponseDnsCache
TTL ManagementDomainBitmap
Routing RulesBatchUpdateDomainRouting()
Update eBPF MapsDNS over HTTPSDNS over TLSDNS over QUICTraditional UDP/TCP
```

Sources: [control/control\_plane.go414-465](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L414-L465) [control/control\_plane\_core.go608-651](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go#L608-L651)

## Configuration and Lifecycle Management

### Application Lifecycle

The application lifecycle is managed through the main control plane with support for configuration reloading:

```text
Parse ConfigConfig ValidConfig InvalidSetup CompleteStart ListenersReload SignalStop SignalNew ConfigReload FailedCleanup CompleteLoadingValidatingInitializingReadyServingReloadingShutting
```

### Configuration Processing

Configuration flows through multiple stages including parsing, validation, and optimization:

```text
Runtime ConfigurationProcessing PipelineConfiguration SourcesUser Config Files
.dae filesInclude Files
dns.dae, routing.daeSubscription URLs
External Proxy ListsConfig Merger
Handle IncludesConfig Parser
Sections to StructsConfig Validator
Syntax ChecksRules Optimizer
GeoIP/GeoSite ExpansionGlobal SettingsDNS ConfigurationRouting RulesNode Groups
```

Sources: [control/control\_plane.go82-509](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane.go#L82-L509)

## Network Interface Management

### Interface Binding Strategy

dae supports both automatic interface detection and explicit configuration, with lazy binding for interfaces that may not be available at startup:

```text
WAN BindingLAN BindingInterface ManagementInterfaceManager
component.InterfaceManagerLazy Binding
Interface Not FoundAutomatic Rebinding
Interface DetectedinitlinkCallbacknewlinkCallbackdellinkCallback_bindLan()initlinkCallbacknewlinkCallbackdellinkCallback_bindWan()
```

Sources: [control/control\_plane\_core.go202-233](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go#L202-L233) [control/control\_plane\_core.go404-431](https://github.com/daeuniverse/dae/blob/3a846ff2/control/control_plane_core.go#L404-L431)