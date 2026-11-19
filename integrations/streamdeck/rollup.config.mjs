import commonjs from "@rollup/plugin-commonjs";
import nodeResolve from "@rollup/plugin-node-resolve";
import typescript from "@rollup/plugin-typescript";

/** @type {import("rollup").RollupOptions} */
export default {
  input: "src/plugin.ts",
  output: {
    file: "com.toldwell.twcc.sdPlugin/bin/plugin.js",
    format: "cjs",
  },
  plugins: [
    nodeResolve({ browser: false, exportConditions: ["node"] }),
    commonjs(),
    typescript({ noEmitOnError: true }),
  ],
  external: [],
};
