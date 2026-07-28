# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# Project-specific Compose invariants.
package compose

import rego.v1

required_services := {"app-a", "app-b", "certgen", "edge"}

long_running_services := required_services - {"certgen"}

deny contains msg if {
	some name in required_services
	object.get(input.services, name, null) == null
	msg := sprintf("required service is missing: %s", [name])
}

deny contains msg if {
	some name in long_running_services
	input.services[name].read_only != true
	msg := sprintf("service %s must use a read-only root filesystem", [name])
}

deny contains msg if {
	some name in long_running_services
	not "ALL" in input.services[name].cap_drop
	msg := sprintf("service %s must drop all Linux capabilities", [name])
}

deny contains msg if {
	some name in long_running_services
	not "no-new-privileges:true" in input.services[name].security_opt
	msg := sprintf("service %s must prevent privilege escalation", [name])
}

deny contains msg if {
	some name in long_running_services
	object.get(input.services[name], "pids_limit", null) == null
	msg := sprintf("service %s must set a process limit", [name])
}

deny contains msg if {
	some name in long_running_services
	object.get(input.services[name], "mem_limit", null) == null
	msg := sprintf("service %s must set a memory limit", [name])
}

deny contains msg if {
	input.networks.backend.internal != true
	msg := "backend network must remain internal"
}

deny contains msg if {
	some port in input.services.edge.ports
	not startswith(port, "127.0.0.1:")
	msg := sprintf("edge port must bind only to loopback: %s", [port])
}

deny contains msg if {
	input.services.certgen.network_mode != "none"
	msg := "certificate generator must remain network-isolated"
}

deny contains msg if {
	input.services.certgen.read_only != true
	msg := "certificate generator must use a read-only root filesystem"
}

# EOF
