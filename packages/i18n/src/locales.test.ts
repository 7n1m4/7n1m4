import fs from 'node:fs'
import path from 'node:path'

import { fileURLToPath } from 'node:url'

import yaml, { isMap, parseDocument } from 'yaml'

import { describe, expect, it } from 'vitest'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const LOCALES_DIR = path.resolve(__dirname, 'locales')

const SUPPORTED_LOCALES = [
  'en',
  'es',
  'fr',
  'id',
  'ja',
  'ko',
  'ru',
  'vi',
  'zh-Hans',
  'zh-Hant',
]

function extractLeafKeys(obj: any, prefix = ''): string[] {
  const keys: string[] = []
  if (!obj || typeof obj !== 'object')
    return keys

  for (const [k, v] of Object.entries(obj)) {
    const keyPath = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      keys.push(...extractLeafKeys(v, keyPath))
    }
    else {
      keys.push(keyPath)
    }
  }
  return keys
}

function getAtPath(obj: any, dottedPath: string): unknown {
  return dottedPath.split('.').reduce<any>((value, segment) => value?.[segment], obj)
}

function checkDuplicateKeys(filePath: string): string[] {
  const content = fs.readFileSync(filePath, 'utf8')
  const duplicates: string[] = []
  const doc = parseDocument(content)

  function checkMap(node: any, p: string[] = []) {
    if (!isMap(node))
      return
    const seen = new Set<string>()
    node.items.forEach((item: any) => {
      const k = item.key?.value ?? item.key?.toString()
      if (seen.has(k)) {
        duplicates.push([...p, k].join('.'))
      }
      seen.add(k)
      if (isMap(item.value)) {
        checkMap(item.value, [...p, k])
      }
    })
  }

  checkMap(doc.contents)
  return duplicates
}

describe('@proj-anima/i18n locale integrity', () => {
  it('has all 10 canonical locales present in locales directory', () => {
    const dirs = fs.readdirSync(LOCALES_DIR, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => d.name)

    for (const locale of SUPPORTED_LOCALES) {
      expect(dirs).toContain(locale)
    }
  })

  it('contains valid syntax and zero duplicate keys in all locale YAML files', () => {
    for (const locale of SUPPORTED_LOCALES) {
      const localeDir = path.join(LOCALES_DIR, locale)
      const files = fs.readdirSync(localeDir).filter(file => file.endsWith('.yaml'))
      expect(files.length, `No YAML files for locale: ${locale}`).toBeGreaterThan(0)
      for (const file of files) {
        const filePath = path.join(localeDir, file)
        const content = fs.readFileSync(filePath, 'utf8')
        expect(() => yaml.parse(content), `Invalid YAML in ${filePath}`).not.toThrow()
        const dups = checkDuplicateKeys(filePath)
        expect(dups, `Duplicate keys in ${filePath}: ${dups.slice(0, 5).join(', ')}`).toEqual([])
      }
    }
  })

  it('maintains 100% key parity for onboarding.yaml across all supported languages', () => {
    const enPath = path.join(LOCALES_DIR, 'en', 'onboarding.yaml')
    if (!fs.existsSync(enPath)) {
      // Pending Onboarding V3 YAML creation
      return
    }

    const enData = yaml.parse(fs.readFileSync(enPath, 'utf8')) || {}
    const enKeys = extractLeafKeys(enData)
    expect(enKeys.length).toBeGreaterThan(50)

    for (const locale of SUPPORTED_LOCALES) {
      if (locale === 'en')
        continue
      const targetPath = path.join(LOCALES_DIR, locale, 'onboarding.yaml')
      expect(fs.existsSync(targetPath), `Missing onboarding.yaml for locale: ${locale}`).toBe(true)

      const targetIndexPath = path.join(LOCALES_DIR, locale, 'index.ts')
      if (fs.existsSync(targetIndexPath)) {
        const indexContent = fs.readFileSync(targetIndexPath, 'utf8')
        expect(indexContent, `Locale ${locale}/index.ts must register onboarding module`).toContain('onboarding')
      }

      const targetData = yaml.parse(fs.readFileSync(targetPath, 'utf8')) || {}
      const targetKeys = new Set(extractLeafKeys(targetData))

      const missing = enKeys.filter(k => !targetKeys.has(k))
      expect(missing, `Locale ${locale} is missing keys in onboarding.yaml: ${missing.slice(0, 5).join(', ')}`).toEqual([])
    }
  })

  it('has every settings.pages.* catalog title/description key in en/settings.yaml', () => {
    const catalogPath = path.resolve(__dirname, '../../../apps/flutter/lib/features/settings/settings_catalog.dart')
    expect(fs.existsSync(catalogPath), `Missing settings catalog: ${catalogPath}`).toBe(true)
    const catalog = fs.readFileSync(catalogPath, 'utf8')
    const catalogKeys = new Set(
      [...catalog.matchAll(/(?:titleKey|descriptionKey):\s*(['"])(settings\.pages\.[^'"]+)\1/g)].map(m => m[2]),
    )
    expect(catalogKeys.size).toBe(31)

    const enData = yaml.parse(fs.readFileSync(path.join(LOCALES_DIR, 'en', 'settings.yaml'), 'utf8')) || {}
    const missing = [...catalogKeys].filter(k => getAtPath(enData, k) === undefined)
    expect(missing, `en/settings.yaml is missing catalog page keys: ${missing.join(', ')}`).toEqual([])

    const blank = [...catalogKeys].filter((k) => {
      const value = getAtPath(enData, k)
      return typeof value !== 'string' || value.trim() === ''
    })
    expect(blank, `en/settings.yaml has empty catalog page values: ${blank.join(', ')}`).toEqual([])
  })

  it('maintains 100% key parity for shell.yaml across all supported languages', () => {
    const enPath = path.join(LOCALES_DIR, 'en', 'shell.yaml')
    if (!fs.existsSync(enPath)) {
      // Pending shell YAML creation
      return
    }

    const enData = yaml.parse(fs.readFileSync(enPath, 'utf8')) || {}
    const enKeys = extractLeafKeys(enData)
    expect(enKeys.length).toBeGreaterThan(50)

    for (const locale of SUPPORTED_LOCALES) {
      if (locale === 'en')
        continue
      const targetPath = path.join(LOCALES_DIR, locale, 'shell.yaml')
      expect(fs.existsSync(targetPath), `Missing shell.yaml for locale: ${locale}`).toBe(true)

      const targetIndexPath = path.join(LOCALES_DIR, locale, 'index.ts')
      if (fs.existsSync(targetIndexPath)) {
        const indexContent = fs.readFileSync(targetIndexPath, 'utf8')
        expect(indexContent, `Locale ${locale}/index.ts must register shell module`).toContain('shell')
      }

      const targetData = yaml.parse(fs.readFileSync(targetPath, 'utf8')) || {}
      const targetKeys = new Set(extractLeafKeys(targetData))

      const missing = enKeys.filter(k => !targetKeys.has(k))
      expect(missing, `Locale ${locale} is missing keys in shell.yaml: ${missing.slice(0, 5).join(', ')}`).toEqual([])
    }
  })
})
