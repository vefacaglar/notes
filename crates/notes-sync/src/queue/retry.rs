use std::time::Duration;

/// Başarısız ağ ve senkronizasyon istekleri için yeniden deneme ve gecikme politikası.
///
/// Üstel geri çekilme (exponential backoff) ve rastgele dalgalanma (jitter) hesaplar:
/// `delay = min(initial_backoff * multiplier^retry_count, max_backoff) ± jitter`
#[derive(Debug, Clone, PartialEq)]
pub struct RetryPolicy {
    /// İzin verilen maksimum yeniden deneme sayısı
    pub max_retries: u32,
    /// İlk başarısızlık sonrası taban bekleme süresi
    pub initial_backoff: Duration,
    /// İzin verilen tavan (maksimum) bekleme süresi
    pub max_backoff: Duration,
    /// Her denemede gecikmenin katlanma katsayısı (varsayılan: 2.0)
    pub multiplier: f64,
    /// Rastgele gecikme dalgalanma faktörü (0.0 .. 1.0, örn: 0.2 -> ±%20 dalgalanma)
    pub jitter_factor: f64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 5,
            initial_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(60),
            multiplier: 2.0,
            jitter_factor: 0.2,
        }
    }
}

impl RetryPolicy {
    /// Yeni bir `RetryPolicy` oluşturur.
    pub fn new(max_retries: u32, initial_backoff: Duration, max_backoff: Duration) -> Self {
        Self {
            max_retries,
            initial_backoff,
            max_backoff,
            multiplier: 2.0,
            jitter_factor: 0.2,
        }
    }

    /// Maksimum yeniden deneme sayısını ayarlar.
    pub fn with_max_retries(mut self, max_retries: u32) -> Self {
        self.max_retries = max_retries;
        self
    }

    /// Katlanma çarpanını ayarlar.
    pub fn with_multiplier(mut self, multiplier: f64) -> Self {
        self.multiplier = multiplier;
        self
    }

    /// Jitter faktörünü ayarlar (0.0 = dalgalanmasız, 0.2 = ±%20).
    pub fn with_jitter_factor(mut self, jitter_factor: f64) -> Self {
        self.jitter_factor = jitter_factor.clamp(0.0, 1.0);
        self
    }

    /// Belirtilen deneme sayısında tekrar denenip denenmeyeceğini sorgular.
    pub fn should_retry(&self, current_attempts: u32) -> bool {
        current_attempts < self.max_retries
    }

    /// Jitter olmaksızın deterministik taban gecikmeyi hesaplar.
    pub fn calculate_base_delay(&self, retry_count: u32) -> Duration {
        if retry_count == 0 {
            return self.initial_backoff;
        }

        let base_millis = self.initial_backoff.as_millis() as f64
            * self.multiplier.powi(retry_count as i32);
        let max_millis = self.max_backoff.as_millis() as f64;
        let clamped = base_millis.min(max_millis);

        Duration::from_millis(clamped as u64)
    }

    /// Rastgele jitter (dalgalanma) içeren gecikme süresini hesaplar.
    pub fn calculate_delay_with_jitter(&self, retry_count: u32) -> Duration {
        let base = self.calculate_base_delay(retry_count);
        if self.jitter_factor <= 0.0 {
            return base;
        }

        let base_millis = base.as_millis() as f64;
        let min_factor = (1.0 - self.jitter_factor).max(0.0);
        let max_factor = 1.0 + self.jitter_factor;

        let random_fraction: f64 = rand::random::<f64>();
        let jittered_multiplier = min_factor + random_fraction * (max_factor - min_factor);
        let jittered_millis = base_millis * jittered_multiplier;

        let max_millis = self.max_backoff.as_millis() as f64;
        let clamped = jittered_millis.min(max_millis).max(0.0);

        Duration::from_millis(clamped as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_retry_policy_base_delay_exponential_growth() {
        let policy = RetryPolicy::new(
            5,
            Duration::from_millis(100),
            Duration::from_secs(10),
        )
        .with_multiplier(2.0);

        assert_eq!(policy.calculate_base_delay(0), Duration::from_millis(100));
        assert_eq!(policy.calculate_base_delay(1), Duration::from_millis(200));
        assert_eq!(policy.calculate_base_delay(2), Duration::from_millis(400));
        assert_eq!(policy.calculate_base_delay(3), Duration::from_millis(800));
        assert_eq!(policy.calculate_base_delay(4), Duration::from_millis(1600));
    }

    #[test]
    fn test_retry_policy_max_backoff_clamping() {
        let policy = RetryPolicy::new(
            10,
            Duration::from_millis(500),
            Duration::from_millis(2000),
        );

        assert_eq!(policy.calculate_base_delay(0), Duration::from_millis(500));
        assert_eq!(policy.calculate_base_delay(1), Duration::from_millis(1000));
        assert_eq!(policy.calculate_base_delay(2), Duration::from_millis(2000));
        assert_eq!(policy.calculate_base_delay(5), Duration::from_millis(2000));
        assert_eq!(policy.calculate_base_delay(10), Duration::from_millis(2000));
    }

    #[test]
    fn test_should_retry() {
        let policy = RetryPolicy::default().with_max_retries(3);
        assert!(policy.should_retry(0));
        assert!(policy.should_retry(1));
        assert!(policy.should_retry(2));
        assert!(!policy.should_retry(3));
        assert!(!policy.should_retry(4));
    }

    #[test]
    fn test_jitter_within_bounds() {
        let policy = RetryPolicy::new(
            5,
            Duration::from_millis(1000),
            Duration::from_secs(60),
        )
        .with_jitter_factor(0.2);

        for _ in 0..50 {
            let delay = policy.calculate_delay_with_jitter(0);
            let millis = delay.as_millis();
            // %20 jitter: 800ms .. 1200ms
            assert!((800..=1200).contains(&millis), "Jitter aralık dışı: {millis}");
        }
    }
}
