import {defineConfig} from 'vite';
import {resolve} from 'path';
import autoprefixer from 'autoprefixer';
import inject from '@rollup/plugin-inject';

export default defineConfig({
  plugins: [
    inject({
      $: 'jquery',
      jQuery: 'jquery',
      'window.jQuery': 'jquery',
      include: '**/*.js'
    })
  ],
  root: resolve(__dirname, 'assets'),
  build: {
    outDir: resolve(__dirname, 'public/dist'),
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: {
        'bootstrap.css': resolve(__dirname, 'assets/entry/bootstrap.scss'),
        'bootstrap.test.css': resolve(__dirname, 'assets/entry/bootstrap.test.scss'),
        'bootstrap.js': resolve(__dirname, 'assets/entry/bootstrap.js'),
        'bootstrap.test.js': resolve(__dirname, 'assets/entry/bootstrap.test.js'),
        'dagre-d3.js': resolve(__dirname, 'assets/entry/dagre-d3.js'),
        'dependency_graph.css': resolve(__dirname, 'assets/stylesheets/dependency_graph.scss'),
        'ace.css': resolve(__dirname, 'assets/entry/ace.scss'),
        'ace.js': resolve(__dirname, 'assets/entry/ace.js'),
        'step_edit.js': resolve(__dirname, 'assets/entry/step_edit.js'),
        'anser.js': resolve(__dirname, 'assets/entry/anser.js'),
        'test_result.js': resolve(__dirname, 'assets/entry/test_result.js'),
        'test_result.test.js': resolve(__dirname, 'assets/entry/test_result.test.js'),
        'create_tests.js': resolve(__dirname, 'assets/javascripts/create_tests.js'),
        'job_next_previous.js': resolve(__dirname, 'assets/javascripts/job_next_previous.js'),
        'video.css': resolve(__dirname, 'assets/stylesheets/video.scss'),
        'ws_console.css': resolve(__dirname, 'assets/stylesheets/ws_console.scss'),
        'ansi-colors.css': resolve(__dirname, 'assets/stylesheets/ansi-colors.scss'),
        'ws_console.js': resolve(__dirname, 'assets/javascripts/ws_console.js'),
        // Images
        'logo-16.png': resolve(__dirname, 'assets/images/logo-16.png'),
        'logo-scheduled-16.png': resolve(__dirname, 'assets/images/logo-scheduled-16.png'),
        'logo-blocked-16.png': resolve(__dirname, 'assets/images/logo-blocked-16.png'),
        'logo-execution-16.png': resolve(__dirname, 'assets/images/logo-execution-16.png'),
        'logo-cancelled-16.png': resolve(__dirname, 'assets/images/logo-cancelled-16.png'),
        'logo-passed-16.png': resolve(__dirname, 'assets/images/logo-passed-16.png'),
        'logo-softfailed-16.png': resolve(__dirname, 'assets/images/logo-softfailed-16.png'),
        'logo-failed-16.png': resolve(__dirname, 'assets/images/logo-failed-16.png'),
        'logo-not_complete-16.png': resolve(__dirname, 'assets/images/logo-not_complete-16.png'),
        'logo-aggregate-passed-16.png': resolve(__dirname, 'assets/images/logo-aggregate-passed-16.png'),
        'logo-aggregate-failed-16.png': resolve(__dirname, 'assets/images/logo-aggregate-failed-16.png'),
        'logo-aggregate-softfailed-16.png': resolve(__dirname, 'assets/images/logo-aggregate-softfailed-16.png'),
        'logo-aggregate-not_complete-16.png': resolve(__dirname, 'assets/images/logo-aggregate-not_complete-16.png'),
        'logo-aggregate-aborted-16.png': resolve(__dirname, 'assets/images/logo-aggregate-aborted-16.png'),
        'logo-aggregate-scheduled-16.png': resolve(__dirname, 'assets/images/logo-aggregate-scheduled-16.png'),
        'logo-aggregate-running-16.png': resolve(__dirname, 'assets/images/logo-aggregate-running-16.png'),
        'logo.svg': resolve(__dirname, 'assets/images/logo.svg'),
        'logo-scheduled.svg': resolve(__dirname, 'assets/images/logo-scheduled.svg'),
        'logo-blocked.svg': resolve(__dirname, 'assets/images/logo-blocked.svg'),
        'logo-execution.svg': resolve(__dirname, 'assets/images/logo-execution.svg'),
        'logo-cancelled.svg': resolve(__dirname, 'assets/images/logo-cancelled.svg'),
        'logo-passed.svg': resolve(__dirname, 'assets/images/logo-passed.svg'),
        'logo-softfailed.svg': resolve(__dirname, 'assets/images/logo-softfailed.svg'),
        'logo-failed.svg': resolve(__dirname, 'assets/images/logo-failed.svg'),
        'logo-not_complete.svg': resolve(__dirname, 'assets/images/logo-not_complete.svg'),
        'logo-aggregate-passed.svg': resolve(__dirname, 'assets/images/logo-aggregate-passed.svg'),
        'logo-aggregate-failed.svg': resolve(__dirname, 'assets/images/logo-aggregate-failed.svg'),
        'logo-aggregate-softfailed.svg': resolve(__dirname, 'assets/images/logo-aggregate-softfailed.svg'),
        'logo-aggregate-not_complete.svg': resolve(__dirname, 'assets/images/logo-aggregate-not_complete.svg'),
        'logo-aggregate-aborted.svg': resolve(__dirname, 'assets/images/logo-aggregate-aborted.svg'),
        'logo-aggregate-scheduled.svg': resolve(__dirname, 'assets/images/logo-aggregate-scheduled.svg'),
        'logo-aggregate-running.svg': resolve(__dirname, 'assets/images/logo-aggregate-running.svg'),
        'terminal.svg': resolve(__dirname, 'assets/images/terminal.svg'),
        'suse.png': resolve(__dirname, 'assets/images/suse.png'),
        'audio.svg': resolve(__dirname, 'assets/images/audio.svg')
      },
      output: {
        manualChunks(id) {
          if (id.includes('node_modules')) {
            if (id.includes('ace-builds')) return 'ace-vendor';
            if (id.includes('d3') || id.includes('dagre')) return 'graph-vendor';
            if (id.includes('bootstrap') || id.includes('jquery')) return 'core-vendor';
            return 'vendor';
          }
        }
      }
    },
    chunkSizeWarningLimit: 1000
  },
  css: {
    postcss: {
      plugins: [autoprefixer()]
    },
    preprocessorOptions: {
      scss: {
        loadPaths: [resolve(__dirname, 'node_modules')],
        quietDeps: true,
        // Silence deprecations that are prevalent in Bootstrap 5.3 and older SCSS
        silenceDeprecations: ['import', 'global-builtin', 'color-functions', 'if-function']
      }
    }
  },
  resolve: {
    alias: {
      // Handle imports that were relative to assets/ in AssetPack
      '@node_modules': resolve(__dirname, 'node_modules'),
      '@javascripts': resolve(__dirname, 'assets/javascripts'),
      '@stylesheets': resolve(__dirname, 'assets/stylesheets'),
      '@images': resolve(__dirname, 'assets/images'),
      '@3rdparty': resolve(__dirname, 'assets/3rdparty')
    }
  }
});
