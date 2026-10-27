window.onload = function () {
  const defaultDefinitionUrl = '/openapi.yaml';
  const definitionURL = defaultDefinitionUrl;
  window.ui = SwaggerUIBundle({
    url: definitionURL,
    dom_id: '#swagger-ui',
    deepLinking: true,
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
    plugins: [SwaggerUIBundle.plugins.DownloadUrl],
    layout: 'StandaloneLayout',
    queryConfigEnabled: true,
    validatorUrl: 'https://validator.swagger.io/validator'
  });
};
