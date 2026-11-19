import type { InstanceTypes, JsonObject } from '@companion-module/base'

/** The connection's settings, as Companion keeps them. */
export interface TwccConfig extends JsonObject {
	host: string
	port: number
	token: string
}

/** The module's types for Companion: its config is `TwccConfig`. */
export interface TwccTypes extends InstanceTypes {
	config: TwccConfig
}
