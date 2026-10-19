param([double]$StartSpeed = 337, [double]$ReverseDot = 0, [double]$ReverseDistance = 1)
$samples = Import-Csv -LiteralPath (Join-Path $PSScriptRoot 'swing_capture.csv')
$state = @{ active=$false; peak=0.0; rest=0.0; reverse=0.0; reversePeak=0.0; dirX=0.0; dirY=0.0; dirZ=0.0 }
$previous = $null
$events = [Collections.Generic.List[object]]::new()
$frames = [Collections.Generic.List[object]]::new()
foreach ($sample in $samples) {
    $dt = [double]$sample.dt
    $qx=[double]$sample.hqx; $qy=[double]$sample.hqy; $qz=[double]$sample.hqz; $qw=[double]$sample.hqw
    $yaw = [Math]::Atan2(-2*($qx*$qz+$qw*$qy),1-2*($qx*$qx+$qy*$qy))
    $offsetX = -100*([double]$sample.rz-[double]$sample.hz)
    $offsetY = 100*([double]$sample.rx-[double]$sample.hx)
    $x = $offsetX*[Math]::Cos($yaw)+$offsetY*[Math]::Sin($yaw)
    $y = -$offsetX*[Math]::Sin($yaw)+$offsetY*[Math]::Cos($yaw)
    $z = 100*([double]$sample.ry-[double]$sample.hy)
    $point = @{x=$x; y=$y; z=$z; yaw=$yaw}
    if ($null -eq $previous) { $previous=$point; continue }
    $dx=$x-$previous.x; $dy=$y-$previous.y; $dz=$z-$previous.z
    $distance = [Math]::Sqrt($dx*$dx+$dy*$dy+$dz*$dz)
    $speed = if ($dt -gt 0) { $distance/$dt } else { 0 }
    $yawDelta = [Math]::Abs(($yaw-$previous.yaw)*180/[Math]::PI)
    $previous=$point
    $began=$false; $ended=$false; $reason=''; $alignment=$null; $reverseCandidate=$state.reverse
    if ($dt -le 0 -or $dt -gt 0.1 -or $yawDelta -gt 45) {
        $ended=$state.active; $state.active=$false; $state.rest=0.0; $state.reverse=0.0; $state.peak=0.0
        $reason='invalid interval/yaw'
    } elseif (-not $state.active) {
        if ($speed -gt $StartSpeed) {
            $began=$true; $state.active=$true; $state.peak=$speed
            $state.dirX=$dx/$distance; $state.dirY=$dy/$distance; $state.dirZ=$dz/$distance
            $state.rest=0.0; $state.reverse=0.0; $state.reversePeak=0.0
            $reason='start speed'
        }
    } elseif ($speed -le 50) {
        $state.rest += $dt
        if ($state.rest -ge 0.08) {
            $ended=$true; $state.active=$false; $state.rest=0.0; $state.reverse=0.0; $state.peak=0.0
            $reason='rest'
        }
    } else {
        $state.rest=0.0
        $projection=$dx*$state.dirX+$dy*$state.dirY+$dz*$state.dirZ
        $alignment=$projection/$distance
        if ($alignment -le $ReverseDot) {
            $state.reverse += [Math]::Max(0,-$projection)
            $reverseCandidate=$state.reverse
            $state.reversePeak=[Math]::Max($state.reversePeak,$speed)
            if ($state.reverse -ge $ReverseDistance) {
                $ended=$true; $state.active=$false; $state.reverse=0.0
                $reason='reverse below start speed'
                if ($speed -gt $StartSpeed) {
                    $began=$true; $state.active=$true; $state.peak=$state.reversePeak
                    $state.dirX=$dx/$distance; $state.dirY=$dy/$distance; $state.dirZ=$dz/$distance
                    $reason='reverse restart'
                }
                $state.reversePeak=0.0
            } else { $reason='reverse candidate' }
        } else {
            $state.dirX=$dx/$distance; $state.dirY=$dy/$distance; $state.dirZ=$dz/$distance
            $state.reverse=0.0; $state.reversePeak=0.0; $state.peak=[Math]::Max($state.peak,$speed)
        }
    }
    $frame = [pscustomobject]@{ seconds=[double]$sample.seconds; dt=$dt; speed=$speed; x=$x; y=$y; z=$z;
        dx=$dx; dy=$dy; dz=$dz; alignment=$alignment; reverse=$reverseCandidate;
        began=$began; ended=$ended; active=$state.active; reason=$reason }
    $frames.Add($frame)
    if ($began -or $ended) { $events.Add($frame) }
}
$frames | Export-Csv -LiteralPath (Join-Path $PSScriptRoot 'swing_replay.csv') -NoTypeInformation
$events | Select-Object seconds,speed,began,ended,reason,alignment,reverse | ConvertTo-Json -Depth 4
$frames | Where-Object { $_.seconds -ge 44 -and $_.seconds -le 55 -and ($_.speed -ge 150 -or $_.reason -ne '') } |
    Select-Object seconds,speed,alignment,reverse,began,ended,active,reason | ConvertTo-Json -Depth 4
