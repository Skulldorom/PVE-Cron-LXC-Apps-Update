import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'PVE Cron LXC Apps Update',
  description: 'Documentation for unattended community-scripts LXC application updates on Proxmox VE.',
  base: '/PVE-Cron-LXC-Apps-Update/',
  cleanUrls: true,
  lastUpdated: true,
  metaChunk: true,
  head: [
    ['meta', { name: 'theme-color', content: '#3c82f6' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'PVE Cron LXC Apps Update' }],
    ['meta', { property: 'og:description', content: 'Install, operate, configure, migrate, and troubleshoot unattended LXC app updates on Proxmox VE.' }]
  ],
  themeConfig: {
    search: { provider: 'local' },
    repo: 'Skulldorom/PVE-Cron-LXC-Apps-Update',
    editLink: { pattern: 'https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update/edit/main/docs/:path', text: 'Edit this page on GitHub' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update' }],
    nav: [
      { text: 'Getting Started', link: '/getting-started/installation' },
      { text: 'Guide', link: '/guide/configuration' },
      { text: 'Maintenance', link: '/maintenance/updating' },
      { text: 'Reference', link: '/reference/cli' }
    ],
    sidebar: [
      { text: 'Start', items: [{ text: 'Overview', link: '/' }] },
      { text: 'Getting Started', items: [
        { text: 'Requirements', link: '/getting-started/requirements' },
        { text: 'Installation', link: '/getting-started/installation' },
        { text: 'First Run', link: '/getting-started/first-run' }
      ]},
      { text: 'Guide', items: [
        { text: 'Configuration', link: '/guide/configuration' },
        { text: 'Scheduling', link: '/guide/scheduling' },
        { text: 'Running', link: '/guide/running' },
        { text: 'Status', link: '/guide/status' },
        { text: 'Backups', link: '/guide/backups' },
        { text: 'Notifications', link: '/guide/notifications' },
        { text: 'Healthchecks', link: '/guide/healthchecks' },
        { text: 'Upstream Cache', link: '/guide/upstream-cache' },
        { text: 'Logging', link: '/guide/logging' }
      ]},
      { text: 'Maintenance', items: [
        { text: 'Updating', link: '/maintenance/updating' },
        { text: 'Migration', link: '/maintenance/migration' },
        { text: 'Uninstalling', link: '/maintenance/uninstalling' }
      ]},
      { text: 'Troubleshooting', items: [{ text: 'Symptoms', link: '/troubleshooting/' }] },
      { text: 'Reference', items: [
        { text: 'CLI', link: '/reference/cli' },
        { text: 'Configuration', link: '/reference/configuration' },
        { text: 'Environment', link: '/reference/environment' },
        { text: 'Files', link: '/reference/files' }
      ]},
      { text: 'Development', items: [
        { text: 'Architecture', link: '/development/architecture' },
        { text: 'Testing', link: '/development/testing' }
      ]}
    ],
    footer: { message: 'Independent project. Not affiliated with community-scripts.', copyright: 'Released under the MIT License.' }
  }
})
