param([string]$Path)
$data=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
function Angle($a,$b) { (($a-$b+540)%360)-180 }
$pairs=@(foreach($group in ($data.rows | Group-Object tick)) {
    $b0=$group.Group | Where-Object { $_.stage -eq 'before_input' -and $_.eye -eq 0 } | Select-Object -First 1
    $b1=$group.Group | Where-Object { $_.stage -eq 'before_input' -and $_.eye -eq 1 } | Select-Object -First 1
    $a0=$group.Group | Where-Object { $_.stage -eq 'after_input' -and $_.eye -eq 0 } | Select-Object -First 1
    $a1=$group.Group | Where-Object { $_.stage -eq 'after_input' -and $_.eye -eq 1 } | Select-Object -First 1
    $f0=$group.Group | Where-Object { $_.stage -eq 'final' -and $_.eye -eq 0 } | Select-Object -First 1
    $f1=$group.Group | Where-Object { $_.stage -eq 'final' -and $_.eye -eq 1 } | Select-Object -First 1
    if($b0 -and $b1 -and $a0 -and $a1 -and $f0 -and $f1) {
        [pscustomobject]@{
            tick=$group.Name
            yawBefore=(Angle $b1.yaw $b0.yaw)
            yawAfter=(Angle $a1.yaw $a0.yaw)
            yawFinal=(Angle $f1.yaw $f0.yaw)
            pitchFinal=(Angle $f1.pitch $f0.pitch)
            rollFinal=(Angle $f1.roll $f0.roll)
            pawnChange0=(Angle $a0.pawnYaw $b0.pawnYaw)
            pawnChange1=(Angle $a1.pawnYaw $b1.pawnYaw)
            baseSeparation=[math]::Sqrt([math]::Pow($a1.x-$a0.x,2)+[math]::Pow($a1.y-$a0.y,2)+[math]::Pow($a1.z-$a0.z,2))
            finalSeparation=[math]::Sqrt([math]::Pow($f1.x-$f0.x,2)+[math]::Pow($f1.y-$f0.y,2)+[math]::Pow($f1.z-$f0.z,2))
            yaw0=$f0.yaw; yaw1=$f1.yaw; pawnYaw=$b0.pawnYaw
        }
    }
})
$summary=@(foreach($field in @('yawBefore','yawAfter','yawFinal','pitchFinal','rollFinal','pawnChange0','pawnChange1','baseSeparation','finalSeparation')) {
    $stats=$pairs | ForEach-Object { [math]::Abs($_.$field) } | Measure-Object -Minimum -Maximum -Average
    [pscustomobject]@{field=$field;min=$stats.Minimum;max=$stats.Maximum;mean=$stats.Average}
})
[pscustomobject]@{label=$data.label;pairs=$pairs.Count;summary=$summary;worst=@($pairs | Sort-Object { [math]::Abs($_.yawFinal) } -Descending | Select-Object -First 5)} | ConvertTo-Json -Depth 5 -Compress
