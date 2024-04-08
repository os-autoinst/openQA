import js from "@eslint/js";
import eslintConfigPrettier from "eslint-config-prettier";
import eslintPluginPrettierRecommended from "eslint-plugin-prettier/recommended";

export default [
  js.configs.recommended,
  {
    rules: {
      "no-unused-vars": "off",
      "no-undef": "off",
    }
  },
  eslintConfigPrettier,
  eslintPluginPrettierRecommended,
];
