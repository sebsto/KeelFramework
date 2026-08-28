import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["cdk.out/**", "lib/**/*.js", "lib/**/*.d.ts", "test/**/*.js", "node_modules/**"] },
  ...tseslint.configs.recommended,
  {
    rules: {
      // CDK construct props are structural; an unused prop in a destructure is a
      // real smell, but a leading underscore is the escape hatch.
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/consistent-type-imports": "error",
    },
  },
  {
    // Tests assert on synthesized templates, which are untyped JSON.
    files: ["test/**/*.ts"],
    rules: { "@typescript-eslint/no-explicit-any": "off" },
  },
);
