import { useEffect, useState } from 'react';
import { ActivityIndicator, View } from 'react-native';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { colors } from '../constants/theme';
import { AuthProvider, useAuth } from '../features/auth/AuthProvider';
import { CourseProvider, useCourses } from '../features/courses/CourseProvider';
import { ProgressProvider, useProgress } from '../features/progress/ProgressProvider';
import { OnboardingProvider, useOnboarding } from '../features/onboarding/OnboardingProvider';

// Apenas a splash NATIVA do Android/iOS. Nenhuma segunda splash.
void SplashScreen.preventAutoHideAsync().catch(() => {});

function AppNavigation() {
  const { ready: authReady } = useAuth();
  const { ready: courseReady } = useCourses();
  const { ready: progressReady } = useProgress();
  const { ready: onboardingReady, completed } = useOnboarding();
  const [laidOut, setLaidOut] = useState(false);
  const dataReady = authReady && courseReady && progressReady && onboardingReady;

  useEffect(() => {
    if (!laidOut) return;
    if (dataReady) {
      void SplashScreen.hideAsync().catch(error => console.warn('Splash Lunivo:', error));
      return;
    }
    // Se a nuvem demorar, a splash nativa sai mas as rotas continuam protegidas.
    const fallback = setTimeout(() => {
      void SplashScreen.hideAsync().catch(error => console.warn('Splash Lunivo:', error));
    }, 6000);
    return () => clearTimeout(fallback);
  }, [laidOut, dataReady]);

  return (
    <View style={{ flex: 1, backgroundColor: onboardingReady && !completed ? '#071625' : colors.background }} onLayout={() => setLaidOut(true)}>
      <StatusBar style={onboardingReady && !completed ? 'light' : 'dark'} />
      {!onboardingReady ? <ActivityIndicator style={{ flex: 1 }} color="#9CC5FF" /> : (
        <Stack screenOptions={{ headerShown: false, animation: 'slide_from_right', contentStyle: { backgroundColor: colors.background } }}>
          <Stack.Protected guard={!completed}>
            <Stack.Screen name="onboarding" options={{ animation: 'fade' }} />
          </Stack.Protected>
          <Stack.Protected guard={completed}>
            <Stack.Screen name="index" options={{ animation: 'none' }} />
            <Stack.Screen name="courses" options={{ animation: 'fade', animationDuration: 180 }} />
            <Stack.Screen name="profile" options={{ animation: 'fade', animationDuration: 180 }} />
            <Stack.Screen name="auth" />
            <Stack.Screen name="lesson/[lessonId]" />
            <Stack.Screen name="result" options={{ animation: 'fade', animationDuration: 200 }} />
          </Stack.Protected>
        </Stack>
      )}
    </View>
  );
}

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <AuthProvider>
        <CourseProvider>
          <ProgressProvider>
            <OnboardingProvider>
              <AppNavigation />
            </OnboardingProvider>
          </ProgressProvider>
        </CourseProvider>
      </AuthProvider>
    </SafeAreaProvider>
  );
}
