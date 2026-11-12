import { DocsHeader } from "./src/components/DocsHeader";
import { createPress } from "fumapress";
import { metaSchema, pageSchema } from "fumapress/schema";
import { defineDocs } from "fumadocs-mdx/macro";
import { defineI18n } from "fumadocs-core/i18n";
import { i18nProvider, uiTranslations } from "fumadocs-ui/i18n";

const i18n = defineI18n(
  {
    languages: ["zh", "en"],
    defaultLanguage: "zh",
    hideLocale: "never",
    fallbackLanguage: null,
  },
);
const translations = i18n
  .translations()
  .extend(uiTranslations())
  .add({ zh: { displayName: "中文" }, en: { displayName: "English" } });

const docs = defineDocs({
  dir: "content",
  docs: {
    async: true,
    schema: pageSchema,
    lastModified: true,
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

export default createPress(docs.toFumadocsSource(), {
  i18n: { ...i18n, parser: "dir" },
}).config({
  site: {
    name: "ZigFS Documentation",
    // Set this in production to enable canonical URLs and sitemap generation.
    baseUrl: "https://docs.zigfs.io",
  },
  head: [
    { tag: "link", attrs: { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" } },
    { tag: "link", attrs: { rel: "preconnect", href: "https://fonts.googleapis.com" } },
    { tag: "link", attrs: { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" } },
    {
      tag: "link",
      attrs: {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Geist:ital,wght@0,100..900;1,100..900&family=JetBrains+Mono:ital,wght@0,100..800;1,100..800&display=swap",
      },
    },
  ],
  ui: {
    layoutProps: ({ lang }) => ({
      i18n: true,
      nav: { title: lang === "zh" ? "ZigFS 文档" : "ZigFS Documentation" },
    }),
    renderPage(props) {
      return props.renderDefault({
        layoutProps: {
          containerProps: {
            style: {
              gridTemplate: '"header header header header header" "sidebar sidebar toc-popover toc toc" "sidebar sidebar tabs toc toc" "sidebar sidebar main toc toc" 1fr / minmax(min-content, 1fr) var(--fd-sidebar-col) minmax(0, calc(var(--fd-layout-width,97rem) - var(--fd-sidebar-width) - var(--fd-toc-width))) var(--fd-toc-width) minmax(min-content, 1fr)',
            },
          },
          slots: { header: DocsHeader, languageSelect: false, themeSwitch: false },
        },
      });
    },
    translations,
    providerProps: ({ lang }) => ({ i18n: i18nProvider(translations, lang) }),
  },
});
