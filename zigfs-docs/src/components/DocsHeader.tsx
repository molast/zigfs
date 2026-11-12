'use client';

import type { ComponentProps } from 'react';
import { useI18n } from 'fumadocs-ui/contexts/i18n';
import Link from 'fumadocs-core/link';
import { useDocsLayout } from 'fumadocs-ui/layouts/docs';
import { LanguageMenu } from './LanguageMenu';
import { ThemeSwitch } from 'fumadocs-ui/layouts/shared/slots/theme-switch';

export function DocsHeader({ className = '', ...props }: ComponentProps<'header'>) {
  const { slots } = useDocsLayout();
  const { locale = 'zh' } = useI18n();
  const chinese = locale === 'zh';
  const links = [
    ['getting-started', chinese ? '快速开始' : 'Getting Started'],
    ['s3-api', 'S3 API'],
    ['cli', 'CLI'],
    ['administration', chinese ? '管理中心' : 'Administration'],
  ];

  return (
    <header
      {...props}
      id="nd-subnav"
      className={`[grid-area:header] sticky top-(--fd-docs-row-1) z-30 flex h-(--fd-header-height) items-center gap-2 border-b bg-fd-background/95 px-3 backdrop-blur-sm layout:[--fd-header-height:--spacing(14)] ${className}`}
    >
      <Link href={`/${locale}`} className="flex min-w-0 items-center gap-2 text-sm font-semibold">
        <img src="/logo.svg" alt="" width={28} height={28} />
        <span className="truncate">{chinese ? 'ZigFS 文档' : 'ZigFS Docs'}</span>
      </Link>
      <nav aria-label={chinese ? '主导航' : 'Main navigation'} className="ms-6 hidden items-center gap-5 text-sm lg:flex">
        {links.map(([slug, label]) => (
          <Link key={slug} href={`/${locale}/${slug}`} className="text-fd-muted-foreground hover:text-fd-foreground">{label}</Link>
        ))}
      </nav>
      <div className="ms-auto flex shrink-0 items-center gap-2">
        <LanguageMenu />
        <ThemeSwitch />
        {slots.searchTrigger && <slots.searchTrigger.sm hideIfDisabled className="md:hidden" />}
        {slots.sidebar && (
          <slots.sidebar.trigger className="rounded-md p-2 hover:bg-fd-accent md:hidden">
            <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </slots.sidebar.trigger>
        )}
      </div>
    </header>
  );
}
