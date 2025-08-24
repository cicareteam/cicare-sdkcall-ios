import UIKit

class MultiLayerGradientView: UIView {
    
    private let layer1 = CAGradientLayer()
    private let layer2 = CAGradientLayer()
    private let layer3 = CAGradientLayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        // ===== Layer 1: Horizontal Gradient =====
        layer1.colors = [
            UIColor(red: 1, green: 0.96, blue: 0.87, alpha: 1).cgColor, // #FFF4DF
            UIColor.white.cgColor,                                      // #FFFFFF
            UIColor(red: 0.85, green: 1, blue: 1, alpha: 1).cgColor      // #DAFFFF
        ]
        layer1.startPoint = CGPoint(x: 0.25, y: 0.5)
        layer1.endPoint   = CGPoint(x: 1, y: 0.5)
        layer1.locations  = [0.0, 0.5, 1.0]
        self.layer.addSublayer(layer1)
        
        // ===== Layer 2: Vertical Fade =====
        layer2.colors = [
            UIColor(white: 0.97, alpha: 0).cgColor,
            UIColor(white: 0.97, alpha: 1).cgColor // #F6F6F6
        ]
        layer2.startPoint = CGPoint(x: 0.5, y: 0.0)
        layer2.endPoint   = CGPoint(x: 0.5, y: 1.0)
        layer2.locations  = [0.3167, 1.0]
        self.layer.addSublayer(layer2)
        
        // ===== Layer 3: Diagonal Fade =====
        layer3.colors = [
            UIColor(red: 0.87, green: 0.94, blue: 1, alpha: 0).cgColor,
            UIColor(red: 0.92, green: 1, blue: 1, alpha: 1).cgColor // #EBFFFF
        ]
        layer3.startPoint = CGPoint(x: 1, y: 1)
        layer3.endPoint   = CGPoint(x: 0, y: 0)
        layer3.locations  = [0.3943, 1.0]
        self.layer.addSublayer(layer3)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        [layer1, layer2, layer3].forEach { $0.frame = self.bounds }
    }
}
