//! Temperature history for the graph on the Temperature screen: nozzle and bed, sampled every
//! few seconds from what the UI shows, the last few minutes kept. UI thread only.

use crate::{AppWindow, Heater, Printer, TempSample};
use slint::{ComponentHandle, Model, ModelRc, Timer, TimerMode, VecModel};
use std::time::Duration;

/// 120 samples every 2.5 s: the last 5 minutes
const SAMPLES: usize = 120;
const INTERVAL: Duration = Duration::from_millis(2500);
/// The graph's scale grows in these steps
const STEP: f32 = 50.0;

/// Starts sampling; the history lives as long as the returned timer.
pub fn start(ui: &AppWindow) -> Timer {
    let printer = ui.global::<Printer>();
    printer.set_temp_capacity(SAMPLES as i32);
    printer.set_temp_history(ModelRc::new(VecModel::<TempSample>::default()));
    printer.set_temp_scale(100.0);

    let weak = ui.as_weak();
    let timer = Timer::default();
    timer.start(TimerMode::Repeated, INTERVAL, move || {
        let Some(ui) = weak.upgrade() else { return };
        let p = ui.global::<Printer>();
        let heaters: Vec<Heater> = p.get_top_heaters().iter().collect();
        // Nothing to show while there is no connection
        let Some(sample) = sample(&heaters) else { return };
        let model = p.get_temp_history();
        let Some(vm) = model.as_any().downcast_ref::<VecModel<TempSample>>() else { return };
        if vm.row_count() >= SAMPLES {
            vm.remove(0);
        }
        vm.push(sample);
        let targets = heaters.iter().map(|h| h.target);
        p.set_temp_scale(scale(vm.iter().flat_map(|s| [s.nozzle, s.bed]).chain(targets)));
    });
    timer
}

/// The first nozzle and the bed; -1 for one the printer does not have.
fn sample(heaters: &[Heater]) -> Option<TempSample> {
    let temp = |role: &str| heaters.iter().find(|h| h.role == role && h.number == 0).map(|h| h.temp);
    let (nozzle, bed) = (temp("nozzle"), temp("bed"));
    if nozzle.is_none() && bed.is_none() {
        return None;
    }
    Some(TempSample { nozzle: nozzle.unwrap_or(-1.0), bed: bed.unwrap_or(-1.0) })
}

/// Top of the graph: the highest value with some room above, in whole steps, at least 100°.
fn scale(values: impl Iterator<Item = f32>) -> f32 {
    let highest = values.fold(0.0, f32::max);
    (((highest + 10.0) / STEP).ceil() * STEP).max(100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn heater(role: &str, number: i32, temp: f32) -> Heater {
        Heater { role: role.into(), number, temp, ..Heater::default() }
    }

    #[test]
    fn samples_first_nozzle_and_bed() {
        let s = sample(&[heater("nozzle", 0, 205.0), heater("nozzle", 1, 30.0), heater("bed", 0, 60.0)]).unwrap();
        assert_eq!((s.nozzle, s.bed), (205.0, 60.0));
        let s = sample(&[heater("nozzle", 0, 25.0)]).unwrap();
        assert_eq!((s.nozzle, s.bed), (25.0, -1.0));
        assert!(sample(&[]).is_none());
    }

    #[test]
    fn scale_in_steps() {
        assert_eq!(scale([].into_iter()), 100.0);
        assert_eq!(scale([25.0, 60.0].into_iter()), 100.0);
        assert_eq!(scale([210.0, 60.0].into_iter()), 250.0);
        assert_eq!(scale([245.0].into_iter()), 300.0);
    }
}
