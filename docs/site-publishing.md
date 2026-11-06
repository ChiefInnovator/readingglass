# Website publishing and discovery

The static product site is deployed from `site/` by `.github/workflows/pages.yml`. The canonical URL is `https://chiefinnovator.github.io/readingglass/`. Run `python3 scripts/check-site.py` before publishing.

## SEO, answer engines and generative search

- Semantic, server-delivered HTML contains the product definition, real requirements, preview status, privacy explanation and clear questions/answers.
- A canonical URL, descriptive title/description, social metadata, favicon and social image use the same ReadingGlass identity.
- JSON-LD describes the website, application, source repository and visible FAQs. No invented reviews, ratings, price, customers or performance claims are included.
- A sitemap and internal navigation expose the content. The optional `llms.txt` file is a concise readable index, not a guaranteed ranking mechanism or a prerequisite for AI search.
- All important content is readable without JavaScript. JavaScript is limited to the illustrative original/translation toggle. No analytics, tracking cookies or externally hosted fonts are included.
- Body and interface text use at least 14px. Contrast warnings were corrected; no design-rule suppressions were added.

Google’s [AI search guidance](https://developers.google.com/search/docs/appearance/ai-features) says existing SEO fundamentals apply and no special AI markup is required. Structured data must describe visible content. App markup here does not claim eligibility for [software-app rich results](https://developers.google.com/search/docs/appearance/structured-data/software-app), which have additional offer/review requirements. Indexing, ranking, AI citations and rich results are not guaranteed.

GitHub Pages project sites live under an account domain. A `robots.txt` inside `/readingglass/` is not the domain-root robots policy; do not assume it controls all crawlers. The page permits indexing, the project sitemap is linked, and the default host behavior must remain crawlable. Domain verification and sitemap submission in Google Search Console or Bing Webmaster Tools require the owner’s account access and remain separate from deployment.

## Publishing boundary

The public repository includes source, synthetic tests, portable development docs, model notices and the website. Local investigation history, private captures, machine-specific session/acceptance records, generated output, model weights and signing material are excluded. The site demonstrates invented text rather than user screen captures.

GitHub’s [custom workflow guide](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages) documents the deployment actions used here. A successful workflow establishes deployment; the live URL is checked separately.
