/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
  testEnvironment: "node",
  roots: ["<rootDir>/test"],
  testMatch: ["**/*.test.ts"],
  transform: {
    "^.+\\.tsx?$": ["ts-jest", {}],
  },
  // Synthesizing a stack is not fast, and the assertions run against the
  // synthesized template rather than mocks.
  testTimeout: 60_000,
};
