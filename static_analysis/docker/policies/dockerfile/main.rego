# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# Project-specific Dockerfile invariants.
package dockerfile

import rego.v1

image_arguments := [value |
	some instruction in input
	instruction.Cmd == "arg"
	some value in instruction.Value
	contains(value, "_IMAGE=")
]

users := [value |
	some instruction in input
	instruction.Cmd == "user"
	some value in instruction.Value
]

stage_aliases := {lower(instruction.Value[2]) |
	some instruction in input
	instruction.Cmd == "from"
	count(instruction.Value) >= 3
	lower(instruction.Value[1]) == "as"
}

has_healthcheck if {
	some instruction in input
	instruction.Cmd == "healthcheck"
}

allowed_base_image(value) if {
	contains(value, "@sha256:")
}

allowed_base_image(value) if {
	regex.match(`^\$\{[A-Z][A-Z0-9_]*_IMAGE\}$`, value)
}

allowed_base_image(value) if {
	lower(value) in stage_aliases
}

deny contains msg if {
	count(image_arguments) == 0
	msg := "Dockerfile must declare digest-pinned base image arguments"
}

deny contains msg if {
	some instruction in input
	instruction.Cmd == "from"
	value := instruction.Value[0]
	not allowed_base_image(value)
	msg := sprintf("FROM input must be digest-pinned: %s", [value])
}

deny contains msg if {
	some value in image_arguments
	not regex.match(`@sha256:[0-9a-f]{64}"?$`, value)
	msg := sprintf("base image argument is not digest-pinned: %s", [value])
}

deny contains msg if {
	some instruction in input
	instruction.Cmd == "add"
	msg := "ADD is forbidden; use COPY for repository-owned files"
}

deny contains msg if {
	some instruction in input
	some value in instruction.Value
	contains(lower(value), ":latest")
	msg := sprintf("mutable latest tag is forbidden: %s", [value])
}

deny contains msg if {
	not has_healthcheck
	msg := "runtime image must define a HEALTHCHECK"
}

deny contains msg if {
	count(users) == 0
	msg := "Dockerfile must declare an explicit runtime user"
}

deny contains msg if {
	count(users) > 0
	users[count(users) - 1] != "101:101"
	msg := "final Dockerfile user must be 101:101"
}

# EOF
