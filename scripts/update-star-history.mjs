#!/usr/bin/env node

import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1];
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function dateLabel(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

async function readStargazers(inputPath) {
  const parsed = JSON.parse(await readFile(inputPath, "utf8"));
  return parsed.flat(Infinity).filter((item) => item?.starred_at);
}

async function fetchStargazers(repository, token) {
  if (!token) {
    throw new Error("GITHUB_TOKEN or GH_TOKEN is required when --input is omitted");
  }

  const stargazers = [];
  for (let page = 1; ; page += 1) {
    const response = await fetch(
      `https://api.github.com/repos/${repository}/stargazers?per_page=100&page=${page}`,
      {
        headers: {
          Accept: "application/vnd.github.star+json",
          Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": "2026-03-10",
          "User-Agent": "awesome-nuwa-star-history"
        }
      }
    );

    if (!response.ok) {
      throw new Error(`GitHub API returned ${response.status}: ${await response.text()}`);
    }

    const pageItems = await response.json();
    stargazers.push(...pageItems);
    if (pageItems.length < 100) break;
  }

  return stargazers;
}

function renderChart(repository, stargazers) {
  const stars = stargazers
    .map((item) => new Date(item.starred_at))
    .filter((date) => !Number.isNaN(date.getTime()))
    .sort((a, b) => a - b);

  if (stars.length === 0) {
    throw new Error("No timestamped stargazers were returned");
  }

  const width = 960;
  const height = 480;
  const margin = { top: 86, right: 36, bottom: 64, left: 72 };
  const chartWidth = width - margin.left - margin.right;
  const chartHeight = height - margin.top - margin.bottom;
  const start = stars[0].getTime();
  const end = Math.max(stars.at(-1).getTime(), start + 86_400_000);
  const yMaximum = Math.max(10, Math.ceil(stars.length / 50) * 50);
  const x = (time) => margin.left + ((time - start) / (end - start)) * chartWidth;
  const y = (count) => margin.top + chartHeight - (count / yMaximum) * chartHeight;

  const points = [[x(start), y(0)]];
  stars.forEach((star, index) => points.push([x(star.getTime()), y(index + 1)]));
  const linePath = points
    .map(([pointX, pointY], index) => `${index === 0 ? "M" : "L"} ${pointX.toFixed(2)} ${pointY.toFixed(2)}`)
    .join(" ");
  const areaPath = `${linePath} L ${x(end).toFixed(2)} ${y(0).toFixed(2)} Z`;

  const yTicks = Array.from({ length: 6 }, (_, index) => Math.round((yMaximum / 5) * index));
  const xTicks = Array.from({ length: 6 }, (_, index) => start + ((end - start) / 5) * index);
  const gridLines = yTicks
    .map(
      (tick) => `
    <line x1="${margin.left}" y1="${y(tick)}" x2="${width - margin.right}" y2="${y(tick)}" stroke="#30363d" stroke-width="1" />
    <text x="${margin.left - 14}" y="${y(tick) + 5}" text-anchor="end" fill="#8b949e" font-size="12" font-family="Arial, sans-serif">${tick}</text>`
    )
    .join("");
  const dateTicks = xTicks
    .map(
      (tick) => `
    <line x1="${x(tick)}" y1="${margin.top}" x2="${x(tick)}" y2="${margin.top + chartHeight}" stroke="#30363d" stroke-width="1" stroke-dasharray="3 7" opacity="0.65" />
    <text x="${x(tick)}" y="${height - 30}" text-anchor="middle" fill="#8b949e" font-size="12" font-family="Arial, sans-serif">${dateLabel(tick)}</text>`
    )
    .join("");
  const latestDate = dateLabel(stars.at(-1));

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">${escapeXml(repository)} star history</title>
  <desc id="description">${stars.length} stars from ${dateLabel(start)} through ${latestDate}</desc>
  <rect width="${width}" height="${height}" rx="18" fill="#0d1117" />
  <text x="${margin.left}" y="40" fill="#f0f6fc" font-size="22" font-weight="700" font-family="Arial, sans-serif">${escapeXml(repository)}</text>
  <text x="${width - margin.right}" y="40" text-anchor="end" fill="#f0f6fc" font-size="22" font-weight="700" font-family="Arial, sans-serif">${stars.length} stars</text>
  <text x="${margin.left}" y="65" fill="#8b949e" font-size="14" font-family="Arial, sans-serif">Star History · latest star ${latestDate} UTC</text>
  <g>${gridLines}${dateTicks}</g>
  <path d="${areaPath}" fill="#ec4899" fill-opacity="0.16" />
  <path d="${linePath}" fill="none" stroke="#ec4899" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" />
  <circle cx="${x(end)}" cy="${y(stars.length)}" r="6" fill="#fb923c" stroke="#0d1117" stroke-width="3" />
</svg>
`;
}

const repository = argument("--repo", process.env.GITHUB_REPOSITORY ?? "nuwa-skills/awesome-nuwa");
const outputPath = argument("--output", "site/star-history.png");
const inputPath = argument("--input");
const stargazers = inputPath
  ? await readStargazers(inputPath)
  : await fetchStargazers(repository, process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN);

await mkdir(path.dirname(outputPath), { recursive: true });
await sharp(Buffer.from(renderChart(repository, stargazers)))
  .png({ adaptiveFiltering: true, compressionLevel: 9 })
  .toFile(outputPath);
console.log(`Generated ${outputPath} from ${stargazers.length} timestamped stars`);
