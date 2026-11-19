// Bitfocus's recommended setup for Companion modules (@companion-module/tools), type-aware.
import { generateEslintConfig } from '@companion-module/tools/eslint/config.mjs'

export default generateEslintConfig({ enableTypescript: true })
