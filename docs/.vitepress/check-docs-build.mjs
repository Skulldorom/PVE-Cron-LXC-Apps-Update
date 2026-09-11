import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const dist = 'docs/.vitepress/dist'
const requiredPages = [
  'index.html',
  'getting-started/installation.html',
  'guide/configuration.html',
  'guide/healthchecks.html',
  'maintenance/migration.html',
  'troubleshooting/index.html',
  'reference/cli.html',
]

const missing = requiredPages.filter((page) => !existsSync(join(dist, page)))
if (missing.length) {
  console.error(`Missing generated documentation pages:\n${missing.map((page) => `- ${page}`).join('\n')}`)
  process.exit(1)
}

const home = readFileSync(join(dist, 'index.html'), 'utf8')
const expectedLinks = [
  '/PVE-Cron-LXC-Apps-Update/getting-started/installation.html',
  '/PVE-Cron-LXC-Apps-Update/guide/configuration.html',
  '/PVE-Cron-LXC-Apps-Update/reference/cli.html',
]

const missingLinks = expectedLinks.filter((link) => !home.includes(link))
if (missingLinks.length) {
  console.error(`Homepage is missing expected project-site links:\n${missingLinks.map((link) => `- ${link}`).join('\n')}`)
  process.exit(1)
}

console.log(`Verified ${requiredPages.length} generated documentation pages and ${expectedLinks.length} project-site links.`)
