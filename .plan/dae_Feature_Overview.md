## Feature Overview

Relevant source files

-   [README.md](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md)
-   [component/outbound/outbound.go](https://github.com/daeuniverse/dae/blob/3a846ff2/component/outbound/outbound.go)
-   [docs/en/proxy-protocols.md](https://github.com/daeuniverse/dae/blob/3a846ff2/docs/en/proxy-protocols.md)
-   [docs/zh/proxy-protocols.md](https://github.com/daeuniverse/dae/blob/3a846ff2/docs/zh/proxy-protocols.md)

This document provides a comprehensive overview of the key features and capabilities of the dae system. It focuses on explaining what dae can do, its major components, and how they interact to deliver a high-performance transparent proxy solution. For detailed implementation information, see [System Architecture](https://deepwiki.com/daeuniverse/dae/1.1-system-architecture).

## Core Capabilities

### Real Direct Traffic Splitting

Dae's most significant feature is its "Real Direct" traffic splitting capability. This allows traffic that doesn't need to be proxied to bypass the proxy application entirely, resulting in:

-   Minimal performance loss for direct traffic
-   Reduced resource consumption
-   Improved overall system efficiency

This is achieved through integration with the Linux kernel using eBPF technology, which allows traffic routing decisions to be made at the kernel level.

```text
Direct TrafficProxy TrafficNetwork TrafficeBPF ProgramsRouting
DecisionDirect Path
(Kernel Only)Control PlaneInternetOutbound Connections
```

Sources: [README.md14-16](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L14-L16) [README.md22](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L22-L22)

### Flexible Traffic Routing

Dae provides extensive flexibility in how traffic is routed, allowing users to create sophisticated rules based on:

| Routing Criterion | Description |
| --- | --- |
| Domain name | Route based on destination domain |
| IP address | Route based on destination IP |
| Protocol | Route based on network protocol (TCP/UDP) |
| Port | Route based on destination port |
| Process name | Route based on originating application |
| MAC address | Route based on client MAC (for LAN clients) |
| ToS/DSCP | Route based on Type of Service / DSCP value |

These routing options can be combined and customized to create sophisticated routing rules, including support for:

-   Inverted matching (routing traffic that doesn't match a pattern)
-   Must-direct rules (forcing traffic to bypass the proxy completely)
-   Block rules (dropping unwanted traffic)

```text
ActionsRouting Rule OptionsDomain
MatchingIP
MatchingProtocol
MatchingPort
MatchingProcess
MatchingMAC
MatchingToS/DSCP
MatchingDirect
RoutingProxy
RoutingBlock
ConnectionRouting Rule
```

Sources: [README.md21-26](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L21-L26) [CHANGELOGS.md516](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L516-L516)

### Node Management and Selection

Dae provides robust capabilities for managing proxy nodes (servers) and selecting the best one based on various criteria:

-   Support for multiple node protocols (Shadowsocks, VMess, Trojan, etc.)
-   Node grouping for logical organization
-   Automatic node selection based on:
    -   Lowest latency
    -   Random selection
    -   Fixed node
-   Automatic latency testing for TCP/UDP/IPv4/IPv6 connections
-   Health checking to ensure nodes remain operational

```text
Node DefinitionProxy
NodesSubscription
LinksNode
GroupsSelection
PolicyFixed
NodeRandom
NodeMin Latency
NodeHealth
CheckerLatency
TestingTCP LatencyUDP LatencyIPv4 LatencyIPv6 Latency
```

Sources: [README.md26](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L26-L26) [CHANGELOGS.md187-189](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L187-L189)

### Advanced DNS Resolution

DNS handling is a critical component of dae's functionality, offering:

-   Customizable DNS resolution paths
-   Support for multiple upstream DNS servers
-   DNS routing based on domain patterns
-   DNS caching to improve performance
-   Prevention of DNS leakage
-   Support for various DNS protocols (DoH, DoT, DoH3, DoQ)

```text
DNS QueryDNS ControllerDomain MatcherUpstream SelectorDNS Upstream 1DNS Upstream 2DNS Upstream NDNS CacheDNS Response
```

Sources: [CHANGELOGS.md142-143](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L142-L143) [README.md27](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L27-L27)

### Protocol Support

Dae supports a wide range of proxy protocols including:

-   HTTP(S), naiveproxy
-   Socks (4, 4a, 5)
-   VMess/VLESS (with various transport options including Reality)
-   Shadowsocks (AEAD and Stream Ciphers, with plugin support)
-   ShadowsocksR
-   Trojan (trojan-gfw, trojan-go)
-   Tuic (v5)
-   Juicity
-   Hysteria2
-   Proxy chains (flexible protocol combinations)

```text
Transport OptionsProxy ProtocolsHTTP(S)Socks (4/4a/5)VMess/VLESSShadowsocksShadowsocksRTrojanTuic v5JuicityHysteria2Proxy ChainTCPWebSocketTLSRealitygRPCMeekHTTP UpgradeWS+TLSsimple-obfsv2ray-plugin
```

Sources: [docs/en/proxy-protocols.md](https://github.com/daeuniverse/dae/blob/3a846ff2/docs/en/proxy-protocols.md) [component/outbound/outbound.go](https://github.com/daeuniverse/dae/blob/3a846ff2/component/outbound/outbound.go)

## Network Traffic Flow

Dae processes network traffic through a sophisticated pipeline that ensures optimal routing decisions:

```text
DirectProxyBlockDirect RuleBlock RuleProxy RuleNetwork TrafficeBPF LayerControl Plane
DecisionDirect Path
(Kernel Only)Routing MatcherDrop ConnectionDomain SniffingDNS ControllerDNS ResolutionRouting DecisionNode SelectorOutbound ConnectionInternet
```

Sources: [README.md14-20](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L14-L20)

## Feature to Code Component Mapping

This diagram shows how dae's features map to the actual code components:

```text
Core ComponentsUser FeaturesReal Direct Traffic SplitFlexible Traffic RoutingNode ManagementAdvanced DNSProtocol SupportControlPlane
InterfaceeBPF ManagementRoutingMatcherDnsControllerDialerGroupsBPF MapsTraffic Intercept HooksRulesOptimizerDomain MatcherIP MatcherDNS UpstreamsDNS CacheProtocol DialersNode Health Checker
```

Sources: [README.md14-28](https://github.com/daeuniverse/dae/blob/3a846ff2/README.md#L14-L28) [component/outbound/outbound.go](https://github.com/daeuniverse/dae/blob/3a846ff2/component/outbound/outbound.go)

## Additional Features

### System Integration

-   **Kernel Interactions**: Configures necessary kernel parameters automatically for optimal performance
-   **Firewall Integration**: Can automatically configure firewalld to ensure compatibility
-   **Network Interface Flexibility**: Supports various interfaces including LAN, WAN, IPIP tunnels, link/ppp, and link/tun

### Administrative Features

-   **Service Management**: Can run as a system service with proper lifecycle management
-   **Command Line Interface**: Comprehensive CLI with commands for running, checking, reloading, and suspending
-   **Diagnostics**: Built-in diagnostic tools including latency testing and traffic tracing
-   **Shell Completion**: Support for bash, zsh, and fish shell completion

Sources: [CHANGELOGS.md389-390](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L389-L390) [CHANGELOGS.md575-576](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L575-L576) [CHANGELOGS.md184-186](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L184-L186)

### Performance Features

-   **Memory Optimization**: Carefully manages memory usage for efficiency
-   **Connection State Management**: Maintains UDP connection state for better reliability
-   **Health Checking**: Continuous monitoring of proxy node health and connectivity
-   **Bandwidth Control**: Supports configuring bandwidth limitations for connections

Sources: [CHANGELOGS.md143](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L143-L143) [CHANGELOGS.md188-189](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L188-L189) [CHANGELOGS.md645](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L645-L645)

## Feature Evolution

Dae is under active development, with new features being added regularly. Recent additions include:

-   Support for Reality protocol (for secure TCP connections)
-   DoH, DoT, DoH3, and DoQ DNS protocols
-   Configurable bandwidth settings
-   MPTCP (Multipath TCP) support
-   Support for various types of network interfaces

For a complete history of feature additions, see [Release History](https://deepwiki.com/daeuniverse/dae/1.3-release-history).

Sources: [CHANGELOGS.md135-189](https://github.com/daeuniverse/dae/blob/3a846ff2/CHANGELOGS.md#L135-L189)