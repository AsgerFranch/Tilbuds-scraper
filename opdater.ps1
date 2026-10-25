$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$headers = @{
    "User-Agent" = "Mozilla/5.0"
}

function Get-Utf8Json($url, $extraHeaders = @{}) {
    $h = $headers.Clone()
    foreach ($k in $extraHeaders.Keys) { $h[$k] = $extraHeaders[$k] }
    $res = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing
    $text = if ($res.RawContentStream) {
        [System.Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    } else {
        $res.Content
    }
    return $text | ConvertFrom-Json
}

function Normalize-Key($text) {
    if (-not $text) { return "" }
    return ($text.ToLower() -replace "[^a-zæøå0-9\s]", " " -replace "\s+", " ").Trim()
}

function Add-Benchmark($map, $key, $normUnitPrice, $protein, $kcal) {
    if (-not $key) { return }
    if (-not $map.ContainsKey($key)) {
        $map[$key] = [PSCustomObject]@{ sum = 0.0; count = 0; protSum = 0.0; protCount = 0; kcalSum = 0.0; kcalCount = 0 }
    }
    $entry = $map[$key]
    $entry.sum += $normUnitPrice
    $entry.count += 1
    if ($null -ne $protein) {
        $entry.protSum += $protein
        $entry.protCount += 1
    }
    if ($null -ne $kcal) {
        $entry.kcalSum += $kcal
        $entry.kcalCount += 1
    }
}

$remaNonFoodDepts = @("Husholdning", "Baby og småbørn", "Personlig pleje", "Kiosk")
$tilbudsugenFoodDepts = @("Kød & fisk", "Mejeri & køl", "Frugt & grønt", "Brød & kager", "Frost", "Kolonial", "Drikkevarer", "Slik & snacks")
$stopWords = @("med", "uden", "fra", "til", "eller", "dans", "dansk", "danske", "øko", "økologisk", "økologiske", "hel", "hele", "frisk", "friske", "ekstra", "original", "classic", "stor", "store", "lille", "mini")

# 1. REMA 1000 (api.digital.rema1000.dk) + opbyg pris/protein/kcal-opslag til prissammenligning
Write-Host "1/4 Henter REMA 1000 (api.digital.rema1000.dk)..." -ForegroundColor Cyan
$remaItems = New-Object System.Collections.Generic.List[object]
$benchByKey = @{}

$page = 1
$lastPage = 1
do {
    $url = "https://api.digital.rema1000.dk/api/v3/products?per_page=1000&include=department,category,nutrition_info&page=$page"
    Write-Host "  REMA 1000 side $page..."
    $json = Get-Utf8Json $url
    $lastPage = $json.meta.pagination.last_page

    foreach ($p in $json.data) {
        if (-not $p.prices -or $p.prices.Count -eq 0) { continue }
        $p0 = $p.prices[0]
        $price = [double]$p0.price

        $normalPrice = $null
        if ($p0.price_over_max_quantity -and [double]$p0.price_over_max_quantity -gt $price) {
            $normalPrice = [double]$p0.price_over_max_quantity
        } elseif ($p.prices.Count -gt 1 -and [double]$p.prices[1].price -gt $price) {
            $normalPrice = [double]$p.prices[1].price
        }

        $savedKr = if ($normalPrice) { [Math]::Round($normalPrice - $price, 2) } else { 0 }
        $savedPct = if ($normalPrice -and $normalPrice -gt 0) { [Math]::Round(($savedKr / $normalPrice) * 100, 1) } else { 0 }

        $protein = $null
        $kcal = $null
        if ($p.nutrition_info) {
            $protRow = $p.nutrition_info | Where-Object { $_.name -match "^Protein" } | Select-Object -First 1
            if ($protRow -and $protRow.value -match "([0-9]+[,\.][0-9]+|[0-9]+)" -and $protRow.value -notmatch "<") {
                $protein = [double]($Matches[1].Replace(",", "."))
            }
            $energiRow = $p.nutrition_info | Where-Object { $_.name -match "^Energi" } | Select-Object -First 1
            if ($energiRow -and $energiRow.value -match "([0-9]+(?:[,\.][0-9]+)?)\s*kcal") {
                $kcal = [double]($Matches[1].Replace(",", "."))
            }
        }

        $unitPrice = if ($p0.compare_unit_price) { [double]$p0.compare_unit_price } else { $null }
        $unit = $p0.compare_unit
        $isMassOrVol = ($unit -eq "kg" -or $unit -eq "ltr")
        $proteinPerKr = if ($protein -ne $null -and $unitPrice -gt 0 -and $isMassOrVol) {
            [Math]::Round(($protein * 10) / $unitPrice, 2)
        } else { $null }
        $kcalPerKr = if ($kcal -gt 0 -and $unitPrice -gt 0 -and $isMassOrVol) {
            [Math]::Round(($kcal * 10) / $unitPrice, 0)
        } else { $null }
        $protDensity = if ($protein -gt 0 -and $kcal -gt 0) {
            [Math]::Round(($protein / $kcal) * 100, 1)
        } else { $null }

        $deptName = if ($p.department) { $p.department.name } else { "Øvrige" }
        $catName = if ($p.category) { $p.category.name } else { "" }
        $isFood = $deptName -notin $remaNonFoodDepts

        if ($unit -and $unitPrice -gt 0 -and $isFood) {
            $normUnitPrice = if ($normalPrice -and $price -gt 0) { $unitPrice * ($normalPrice / $price) } else { $unitPrice }
            $nKey = Normalize-Key $p.name
            if ($nKey) {
                Add-Benchmark $benchByKey "$unit|$nKey" $normUnitPrice $protein $kcal
                $words = @($nKey -split " " | Where-Object { $_.Length -ge 3 -and $_ -notin $stopWords -and $_ -notmatch "^[0-9]+$" })
                if ($words.Count -ge 2) {
                    Add-Benchmark $benchByKey "$unit|$($words[0]) $($words[1])" $normUnitPrice $protein $kcal
                }
                foreach ($w in $words) {
                    if ($w.Length -ge 4) {
                        Add-Benchmark $benchByKey "$unit|$w" $normUnitPrice $protein $kcal
                    }
                }
            }
            $cKey = Normalize-Key $catName
            if ($cKey) {
                Add-Benchmark $benchByKey "$unit|cat:$cKey" $normUnitPrice $protein $kcal
                foreach ($cw in ($cKey -split " ")) {
                    if ($cw.Length -ge 4 -and $cw -notin $stopWords) {
                        Add-Benchmark $benchByKey "$unit|cat:$cw" $normUnitPrice $protein $kcal
                    }
                }
            }
        }

        $remaItems.Add([PSCustomObject]@{
            id            = "$($p.id)"
            name          = $p.name
            underline     = $p.underline
            dept          = $deptName
            cat           = $catName
            is_food       = [bool]$isFood
            price         = $price
            normal        = $normalPrice
            is_est_normal = $false
            saved_kr      = $savedKr
            saved_pct     = $savedPct
            is_offer      = [bool]($p0.is_advertised -or $p0.is_campaign -or $savedKr -gt 0)
            is_batch      = [bool]$p.is_batch_item
            max_qty       = $p0.max_quantity
            unit          = $unit
            unit_price    = $unitPrice
            protein_100   = $protein
            prot_per_kr   = $proteinPerKr
            prot_density  = $protDensity
            kcal_100      = $kcal
            kcal_per_kr   = $kcalPerKr
            img           = if ($p.images -and $p.images.Count -gt 0) { $p.images[0].medium } else { $null }
            url           = "https://shop.rema1000.dk/varer/$($p.id)"
        })
    }
    $page++
} while ($page -le $lastPage)

# 2-4. Netto, Føtex & Coop 365discount via Tilbudsugen API (strukturerede kategorier, enhedspriser & madvare-opdeling)
function Fetch-TilbudsugenStore($chainSlug, $storeLabel, $defaultUrl) {
    Write-Host "Henter $storeLabel (tilbudsugen.dk API)..." -ForegroundColor Cyan
    $url = "https://www.tilbudsugen.dk/api/api/product-offers-search/dk/${chainSlug}?page=1&numberPerPage=1000&triggeredFromSearchField=1"
    $res = Get-Utf8Json $url @{ "X-Requested-With" = "XMLHttpRequest" }
    $items = $res.pageOfOrganicProductOffers.items
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($o in $items) {
        if (-not $o.price) { continue }
        $price = [double]$o.price
        if ($price -le 0) { continue }

        $pName = if ($o.productName -and $o.productName.productName) { $o.productName.productName.Trim() } else { "$($o.title)".Trim() }
        $brand = if ($o.brand -and $o.brand.name) { $o.brand.name.Trim() } else { "" }
        $displayName = if ($brand -and $pName -notmatch [regex]::Escape($brand)) { "$pName ($brand)" } else { $pName }

        $dept = if ($o.placementTitle) { $o.placementTitle.Trim() } else { "Øvrige" }
        $cat = if ($o.productVariant -and $o.productVariant.category -and $o.productVariant.category.name) { $o.productVariant.category.name.Trim() } else { "" }
        $isFood = $dept -in $tilbudsugenFoodDepts

        $qType = "$($o.quantityType)".ToLower().TrimEnd(".")
        $unit = if ($qType -eq "kg") { "kg" } elseif ($qType -eq "ltr" -or $qType -eq "l") { "ltr" } elseif ($qType -eq "stk") { "stk" } else { $null }
        $unitPrice = if ($o.pricePerFullUnitOfQuantityType -and [double]$o.pricePerFullUnitOfQuantityType -gt 0) {
            [Math]::Round([double]$o.pricePerFullUnitOfQuantityType, 2)
        } else { $null }

        $commentPart = if ($o.comment) { ($o.comment -replace "\r?\n", " ").Trim() } else { "" }

        # Find normalpris, protein og kcal: 1) eksplicit førpris i tekst, 2) match mod REMA 1000 normalpris-katalog
        $normal = $null
        $isEstNormal = $false
        $protein = $null
        $kcal = $null

        if ($commentPart -match "(?:Normalpris|øvrige dage(?: op til)?|er prisen(?: herefter)?|førpris)\s*:?\s*([0-9]+(?:[,\.][0-9]+)?|-)") {
            $parsed = [double]($Matches[1].Replace(",", ".").TrimEnd("-"))
            if ($parsed -gt $price) { $normal = $parsed }
        }

        $normPName = Normalize-Key $pName
        if ($unit -and $unitPrice -gt 0 -and $normPName) {
            $words = @($normPName -split " " | Where-Object { $_.Length -ge 3 -and $_ -notin $stopWords -and $_ -notmatch "^[0-9]+$" })
            $candKeys = New-Object System.Collections.Generic.List[string]
            $candKeys.Add("$unit|$normPName")
            if ($words.Count -ge 2) { $candKeys.Add("$unit|$($words[0]) $($words[1])") }
            foreach ($w in $words) {
                if ($w.Length -ge 4) { $candKeys.Add("$unit|$w") }
            }
            if ($cat) {
                $normCat = Normalize-Key $cat
                $candKeys.Add("$unit|cat:$normCat")
                $candKeys.Add("$unit|$normCat")
                foreach ($cw in ($normCat -split " ")) {
                    if ($cw.Length -ge 4) {
                        $candKeys.Add("$unit|cat:$cw")
                        $candKeys.Add("$unit|$cw")
                    }
                }
            }

            foreach ($ck in $candKeys) {
                if ($benchByKey.ContainsKey($ck)) {
                    $b = $benchByKey[$ck]
                    if ($null -eq $protein -and $b.protCount -gt 0) {
                        $protein = [Math]::Round($b.protSum / $b.protCount, 1)
                    }
                    if ($null -eq $kcal -and $b.kcalCount -gt 0) {
                        $kcal = [Math]::Round($b.kcalSum / $b.kcalCount, 0)
                    }
                    if (-not $normal -and $b.count -gt 0) {
                        $avgNormUnit = $b.sum / $b.count
                        $estNormal = [Math]::Round($price * ($avgNormUnit / $unitPrice), 2)
                        # Brug kun estimeret normalpris når besparelsen er realistisk (5% - 68%)
                        if ($estNormal -gt ($price * 1.05) -and $estNormal -lt ($price * 3.1)) {
                            $normal = $estNormal
                            $isEstNormal = $true
                        }
                    }
                    if ($normal -and $null -ne $protein) { break }
                }
            }
        }

        $savedKr = if ($normal -and $normal -gt $price) { [Math]::Round($normal - $price, 2) } else { 0 }
        $savedPct = if ($normal -and $normal -gt $price) { [Math]::Round(($savedKr / $normal) * 100, 1) } else { 0 }

        $isMassOrVol = ($unit -eq "kg" -or $unit -eq "ltr")
        $protPerKr = if ($protein -ne $null -and $unitPrice -gt 0 -and $isMassOrVol) {
            [Math]::Round(($protein * 10) / $unitPrice, 2)
        } else { $null }
        $kcalPerKr = if ($kcal -gt 0 -and $unitPrice -gt 0 -and $isMassOrVol) {
            [Math]::Round(($kcal * 10) / $unitPrice, 0)
        } else { $null }
        $protDensity = if ($protein -gt 0 -and $kcal -gt 0) {
            [Math]::Round(($protein / $kcal) * 100, 1)
        } else { $null }

        $qtyPart = if ($o.units -gt 1) { "$($o.units) $($o.unitType) / $($o.quantity) $($o.quantityType)" } elseif ($o.quantity) { "$($o.quantity) $($o.quantityType)" } else { "" }
        $underline = (@($qtyPart, $commentPart) | Where-Object { $_ }) -join " • "
        if ($underline.Length -gt 110) { $underline = $underline.Substring(0, 107) + "..." }

        $list.Add([PSCustomObject]@{
            id            = "$($o.id)"
            name          = $displayName
            underline     = $underline
            dept          = $dept
            cat           = $cat
            is_food       = [bool]$isFood
            price         = $price
            normal        = $normal
            is_est_normal = [bool]$isEstNormal
            saved_kr      = $savedKr
            saved_pct     = $savedPct
            is_offer      = $true
            is_batch      = [bool]($commentPart -match "(?i)partivare|spotvare|begrænset")
            max_qty       = $null
            unit          = $unit
            unit_price    = $unitPrice
            protein_100   = $protein
            prot_per_kr   = $protPerKr
            prot_density  = $protDensity
            kcal_100      = $kcal
            kcal_per_kr   = $kcalPerKr
            img           = if ($o.imageUrl) { $o.imageUrl } else { $o.imageThumbnailUrl }
            url           = if ($o.offerUrl) { $o.offerUrl } else { $defaultUrl }
        })
    }
    return $list
}

$nettoItems  = Fetch-TilbudsugenStore "Netto"       "2/4 Netto"             "https://netto.dk/netto-avisen/"
$foetexItems = Fetch-TilbudsugenStore "F%C3%B8tex"  "3/4 Føtex"             "https://www.foetex.dk/avis/"
$coopItems   = Fetch-TilbudsugenStore "365discount" "4/4 Coop 365discount"  "https://365discount.coop.dk/365avis/"

# Self-check på alle 4 butikker inkl. madvarer, kalorier og rabatberegning
if ($remaItems.Count -lt 1000) { throw "Fejl: REMA 1000 returnerede kun $($remaItems.Count) varer" }
if (($remaItems | Where-Object { $_.kcal_per_kr -gt 0 }).Count -lt 1000) { throw "Fejl: REMA 1000 mangler kcal_per_kr data" }
foreach ($pair in @(
    @{ Name = "Netto"; Items = $nettoItems },
    @{ Name = "Føtex"; Items = $foetexItems },
    @{ Name = "Coop 365"; Items = $coopItems }
)) {
    $c = $pair.Items.Count
    $foodCount = ($pair.Items | Where-Object { $_.is_food }).Count
    $discCount = ($pair.Items | Where-Object { $_.saved_kr -gt 0 }).Count
    if ($c -lt 50 -or $foodCount -lt 30 -or $discCount -lt 20) {
        throw "Self-check fejlede for $($pair.Name): total=$c, madvarer=$foodCount, med rabat=$discCount"
    }
    Write-Host "  $($pair.Name): $c tilbud ($foodCount madvarer, $discCount med beregnet besparelse)" -ForegroundColor Gray
}

$remaOffers = ($remaItems | Where-Object { $_.is_offer }).Count

$payload = [PSCustomObject]@{
    updated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    stores     = [PSCustomObject]@{
        rema1000 = [PSCustomObject]@{
            id        = "rema1000"
            name      = "REMA 1000"
            api_label = "api.digital.rema1000.dk/api/v3"
            color     = "#003d7a"
            has_all   = $true
            total     = $remaItems.Count
            offers    = $remaOffers
            items     = $remaItems
        }
        netto = [PSCustomObject]@{
            id        = "netto"
            name      = "Netto"
            api_label = "tilbudsugen.dk/api (Netto)"
            color     = "#d49b00"
            has_all   = $false
            total     = $nettoItems.Count
            offers    = $nettoItems.Count
            items     = $nettoItems
        }
        foetex = [PSCustomObject]@{
            id        = "foetex"
            name      = "Føtex"
            api_label = "tilbudsugen.dk/api (Føtex)"
            color     = "#0b2545"
            has_all   = $false
            total     = $foetexItems.Count
            offers    = $foetexItems.Count
            items     = $foetexItems
        }
        coop365 = [PSCustomObject]@{
            id        = "coop365"
            name      = "Coop 365discount"
            api_label = "tilbudsugen.dk/api (365discount)"
            color     = "#00843d"
            has_all   = $false
            total     = $coopItems.Count
            offers    = $coopItems.Count
            items     = $coopItems
        }
    }
}

# shortcut: samler alle 4 kæders API-svar i data.js pga. browser-CORS, skift til backend hvis appen skal køre uden lokal opdatering.
$jsContent = "window.REMA_DATA = " + ($payload | ConvertTo-Json -Depth 6 -Compress) + ";"
$outPath = Join-Path $PSScriptRoot "data.js"
[System.IO.File]::WriteAllText($outPath, $jsContent, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Færdig! Gemte REMA 1000 ($($remaItems.Count)), Netto ($($nettoItems.Count)), Føtex ($($foetexItems.Count)), Coop 365 ($($coopItems.Count)) i data.js" -ForegroundColor Green
