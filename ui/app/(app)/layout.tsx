import { Sidebar } from "@/components/layout/sidebar";
import { BottomNav } from "@/components/layout/bottom-nav";

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen overflow-hidden" style={{ background: "var(--color-bg)" }}>
      <Sidebar />
      <div className="flex flex-col flex-1 overflow-hidden">
        {/* pb-16 on mobile so content clears the fixed bottom nav; none on md+ */}
        <div className="flex flex-col flex-1 overflow-auto pb-16 md:pb-0">
          {children}
        </div>
      </div>
      <BottomNav />
    </div>
  );
}
