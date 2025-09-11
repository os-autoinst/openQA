window.onload = function() {
    const defaultDefinitionUrl = "http://localhost:9526/openapi.yaml";
    const definitionURL = defaultDefinitionUrl;

      //<editor-fold desc="Changeable Configuration Block">
      window.ui = SwaggerUIBundle({
        url: definitionURL,
        "dom_id": "#swagger-ui",
        deepLinking: true,
        presets: [
          SwaggerUIBundle.presets.apis,
          SwaggerUIStandalonePreset
        ],
        plugins: [
          SwaggerUIBundle.plugins.DownloadUrl
        ],
        layout: "StandaloneLayout",
        queryConfigEnabled: true,
        validatorUrl: "https://validator.swagger.io/validator",
      })
      //</editor-fold>

};
